"""
connect.py – "Musique Connect": one player, every device a remote (like Spotify Connect).

Each app keeps a WebSocket to /api/connect. Per Jellyfin user, the hub knows the connected
devices and which one is *active* (the one producing sound):

- the active device streams its state (queue, position…) → relayed to the others, which show it;
- any other device sends commands (next, seek, play this…) → relayed to the active device;
- "transfer" moves playback: the target gets the latest state (position extrapolated) and starts
  playing, the previous active device stops.

Messages are JSON objects with a "type" field; the queue / command payloads are opaque here.
"""

import asyncio
import json
import time

from fastapi import WebSocket, WebSocketDisconnect


class Device:
    def __init__(self, ws: WebSocket, device_id: str, name: str, kind: str, volume: float | None = None):
        self.ws = ws
        self.id = device_id
        self.name = name
        self.kind = kind
        self.volume = volume  # the app's playback volume on that device, 0…1

    async def send(self, msg: dict):
        try:
            await self.ws.send_text(json.dumps(msg))
        except Exception:
            pass


class Room:
    """The devices of one Jellyfin user."""

    def __init__(self):
        self.devices: dict[str, Device] = {}
        self.active: str | None = None
        self.state: dict | None = None
        self.state_time = 0.0
        self.lock = asyncio.Lock()

    def listing(self) -> dict:
        return {
            "type": "devices",
            "active": self.active,
            "devices": [{"id": d.id, "name": d.name, "kind": d.kind, "volume": d.volume}
                        for d in self.devices.values()],
        }

    def current_state(self) -> dict | None:
        """Latest state with the position moved forward to now if it's playing."""
        if not self.state:
            return None
        st = dict(self.state)
        if st.get("isPlaying"):
            st["time"] = float(st.get("time") or 0) + (time.time() - self.state_time)
        st["timestamp"] = time.time()
        return st

    async def broadcast(self, msg: dict, exclude: str | None = None):
        await asyncio.gather(*(d.send(msg) for d in list(self.devices.values()) if d.id != exclude))


class Hub:
    def __init__(self):
        self.rooms: dict[str, Room] = {}

    def room(self, user_id: str) -> Room:
        return self.rooms.setdefault(user_id, Room())

    async def serve(self, ws: WebSocket, user_id: str, device_id: str, name: str, kind: str,
                    volume: float | None = None):
        room = self.room(user_id)
        device = Device(ws, device_id, name, kind, volume)
        async with room.lock:
            old = room.devices.get(device_id)
            if old:  # same device reconnecting: drop the stale socket
                try:
                    await old.ws.close()
                except Exception:
                    pass
            room.devices[device_id] = device
        await room.broadcast(room.listing())
        if room.active and room.active != device_id and room.state:
            await device.send({"type": "state", "from": room.active, "state": room.current_state()})

        try:
            while True:
                msg = json.loads(await ws.receive_text())
                if isinstance(msg, dict):
                    await self.handle(room, device, msg)
        except (WebSocketDisconnect, RuntimeError, json.JSONDecodeError):
            pass
        finally:
            async with room.lock:
                if room.devices.get(device_id) is device:
                    del room.devices[device_id]
                    if room.active == device_id:
                        room.active = None
            await room.broadcast(room.listing())

    async def handle(self, room: Room, device: Device, msg: dict):
        kind = msg.get("type")

        if kind == "claim":
            # This device starts producing sound: it becomes the active one, the previous stops.
            previous = room.active
            room.active = device.id
            if previous and previous != device.id and previous in room.devices:
                await room.devices[previous].send({"type": "release"})
            await room.broadcast(room.listing())

        elif kind in ("state", "progress") and room.active is None:
            # A device that plays while nobody is active (the hub restarted, a socket dropped):
            # it is the active one; the others must see it.
            room.active = device.id
            await room.broadcast(room.listing())
            await self.handle(room, device, msg)

        elif kind == "state" and room.active == device.id:
            room.state = msg.get("state") or {}
            room.state_time = time.time()
            await room.broadcast({"type": "state", "from": device.id, "state": room.current_state()}, exclude=device.id)

        elif kind == "progress" and room.active == device.id:
            if room.state is not None:
                for k in ("time", "isPlaying", "duration", "index"):
                    if k in msg:
                        room.state[k] = msg[k]
                room.state_time = time.time()
            await room.broadcast({"type": "progress", "from": device.id, **{k: msg[k] for k in msg if k != "type"}},
                                 exclude=device.id)

        elif kind == "volume":
            try:
                device.volume = min(max(float(msg.get("level")), 0.0), 1.0)
            except (TypeError, ValueError):
                return
            await room.broadcast(room.listing())

        elif kind == "viz" and room.active == device.id:
            # Visualizer bars of the playing device (~20/s), for the others to show.
            await room.broadcast({"type": "viz", "b": msg.get("b")}, exclude=device.id)

        elif kind == "favorite":
            # A device (un)favorited a song: the others update their UI right away.
            ids = [i for i in (msg.get("ids") or []) if isinstance(i, str)][:4]
            if ids:
                await room.broadcast({"type": "favorite", "ids": ids, "value": bool(msg.get("value"))},
                                     exclude=device.id)

        elif kind == "command" and room.active and room.active != device.id:
            target = room.devices.get(room.active)
            if target:
                await target.send({"type": "command", "from": device.id, "command": msg.get("command")})

        elif kind == "transfer":
            target_id = msg.get("to")
            target = room.devices.get(target_id)
            if not target or target_id == room.active:
                return
            previous = room.active
            state = room.current_state()
            room.active = target_id
            if previous and previous in room.devices:
                await room.devices[previous].send({"type": "release"})
            await target.send({"type": "takeover", "state": state})
            await room.broadcast(room.listing())


    def now_playing(self, user_id: str) -> dict | None:
        """What a user is listening to right now (on whichever of their devices), or None."""
        room = self.rooms.get(user_id)
        st = room.current_state() if room and room.active else None
        if not st or not st.get("isPlaying"):
            return None
        queue, index = st.get("queue") or [], int(st.get("index") or 0)
        track = (queue[index] or {}).get("track") if 0 <= index < len(queue) else None
        if not track:
            return None
        artists = ", ".join(a.get("name") or "" for a in track.get("artistItems") or []) or track.get("albumArtist")
        return {"itemId": track.get("id"), "title": track.get("name"), "artist": artists, "album": track.get("album"),
                "artId": track.get("albumId"), "artTag": track.get("albumPrimaryImageTag"),
                "art": track.get("externalArt")}

    async def notify(self, user_ids, msg: dict):
        """A message to every device of these users (account requests for the admins…)."""
        for uid in user_ids:
            room = self.rooms.get(uid)
            if room:
                await room.broadcast(msg)


HUB = Hub()
