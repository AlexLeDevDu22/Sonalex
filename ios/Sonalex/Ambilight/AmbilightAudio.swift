import AVFoundation
import Foundation
import MediaToolbox
import UIKit

// MARK: - Sink (filled from the real-time audio thread)

/// Thread-safe buffer of captured audio (mono Int16) plus a smoothed level for the UI glow.
final class AmbilightAudioSink: @unchecked Sendable {
    static let shared = AmbilightAudioSink()

    struct Chunk {
        let samples: [Int16]
        let sampleRate: Double
        let time: TimeInterval
    }

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var level: Double = 0
    private var bass: Double = 0
    private var lowpass: Double = 0
    /// When false, captured audio is only metered (for the glow and visualizers), not queued.
    private var queueing = false

    // 4-band analyzer for the visualizers (bass, low-mid, high-mid, treble).
    private var lp150: Double = 0
    private var lp600: Double = 0
    private var lp2500: Double = 0
    private var bandPeaks: [Double] = [-40, -40, -40, -40] // dB ceilings
    private var lastWasRemote = false
    private var bandLevels: [Double] = [0, 0, 0, 0]
    private var bandFast: [Double] = [0, 0, 0, 0]
    /// Recent band snapshots, so the bars can be shown when the sound actually reaches the ears.
    private var history: [(time: TimeInterval, bands: [Double])] = []
    private var lastPush: TimeInterval = 0

    func setQueueing(_ on: Bool) {
        lock.lock()
        queueing = on
        if !on { chunks.removeAll() }
        lock.unlock()
    }

    /// Called by the tap with mono Float samples in -1…1.
    func push(_ mono: UnsafeBufferPointer<Float>, sampleRate: Double) {
        guard !mono.isEmpty else { return }
        var sumSq: Double = 0
        var bassSq: Double = 0
        var lp = lowpass
        // One-pole low-pass ~150 Hz for a cheap "bass" envelope.
        let a = 1 - exp(-2 * Double.pi * 150 / max(sampleRate, 1))
        var out = [Int16](repeating: 0, count: mono.count)
        for i in 0..<mono.count {
            let x = Double(max(-1, min(1, mono[i])))
            sumSq += x * x
            lp += a * (x - lp)
            bassSq += lp * lp
            out[i] = Int16(x * 32767)
        }
        let rms = (sumSq / Double(mono.count)).squareRoot()
        let bassRms = (bassSq / Double(mono.count)).squareRoot()
        let now = ProcessInfo.processInfo.systemUptime

        // Bands from cascaded one-pole low-passes, analysed in ~12 ms blocks.
        lock.lock()
        let rate = max(sampleRate, 1)
        let a1 = 1 - exp(-2 * Double.pi * 150 / rate)
        let a2 = 1 - exp(-2 * Double.pi * 600 / rate)
        let a3 = 1 - exp(-2 * Double.pi * 2500 / rate)
        var l1 = lp150, l2 = lp600, l3 = lp2500
        let block = 512
        let chunkDuration = Double(mono.count) / rate
        var start = 0
        while start < mono.count {
            let end = min(start + block, mono.count)
            var e: [Double] = [0, 0, 0, 0]
            for i in start..<end {
                let x = Double(max(-1, min(1, mono[i])))
                l1 += a1 * (x - l1)
                l2 += a2 * (x - l2)
                l3 += a3 * (x - l3)
                e[0] += l1 * l1
                e[1] += (l2 - l1) * (l2 - l1)
                e[2] += (l3 - l2) * (l3 - l2)
                e[3] += (x - l3) * (x - l3)
            }
            let n = Double(end - start)
            let dt = n / rate
            for b in 0..<4 {
                let db = 10 * log10(e[b] / n + 1e-12)
                // Ceiling follows loud moments at once and sinks ~6 dB/s, so each band uses its
                // whole height in quiet and loud songs alike.
                bandPeaks[b] = max(db, bandPeaks[b] - 6 * dt)
                let range = b == 0 ? 22.0 : 26.0
                var v = (db - (bandPeaks[b] - range)) / range
                v = min(max(v, 0), 1)
                v = pow(v, 3.2) // contrast: steady parts stay low, hits jump up
                // Two smoothing stages = a gentle ease-in-out: the first follows the music
                // (rise ~45 ms, fall ~140 ms), the second rounds off starts and stops.
                let tau = v > bandFast[b] ? 0.045 : 0.14
                bandFast[b] += (v - bandFast[b]) * (1 - exp(-dt / tau))
                bandLevels[b] += (bandFast[b] - bandLevels[b]) * (1 - exp(-dt / 0.05))
            }
            history.append((now - chunkDuration + Double(end) / rate, bandLevels))
            start = end
        }
        if history.count > 240 { history.removeFirst(history.count - 240) }
        lastPush = now
        lastWasRemote = false
        lowpass = lp
        // Fast attack, slow release, like a VU meter.
        level = rms > level ? level + (rms - level) * 0.6 : level * 0.92
        bass = bassRms > bass ? bass + (bassRms - bass) * 0.7 : bass * 0.9
        if queueing {
            chunks.append(Chunk(samples: out, sampleRate: sampleRate, time: now))
            // Never hold more than ~3 s (e.g. while the socket reconnects).
            if chunks.count > 400 { chunks.removeFirst(chunks.count - 400) }
        }
        lock.unlock()
    }

    /// The 4 band levels (0…1) to show now: from this device's audio, delayed by its output
    /// latency (`localDelay`, AirPods…), or from the device that plays (Musique Connect).
    /// nil when there's nothing to show (paused, nothing playing anywhere…).
    func bands(localDelay: TimeInterval) -> [Double]? {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPush < 0.4, !history.isEmpty else { return nil }
        // Remote values arrive ~20×/s: show them one message late, interpolated, for smoothness.
        let target = now - (lastWasRemote ? 0.08 : localDelay)
        guard let i = history.lastIndex(where: { $0.time <= target }) else { return history.first?.bands }
        guard i + 1 < history.count else { return history[i].bands }
        let (a, b) = (history[i], history[i + 1])
        let f = (target - a.time) / max(b.time - a.time, 0.001)
        return zip(a.bands, b.bands).map { $0 + ($1 - $0) * min(max(f, 0), 1) }
    }

    /// Bands received from the device that plays (this one is a remote control).
    func pushRemote(_ bands: [Double]) {
        guard bands.count == 4 else { return }
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        if !lastWasRemote { history.removeAll() }
        history.append((now, bands.map { min(max($0, 0), 1) }))
        if history.count > 240 { history.removeFirst(history.count - 240) }
        lastPush = now
        lastWasRemote = true
        lock.unlock()
    }

    /// Chunks captured before `deadline` (systemUptime), oldest first.
    func drain(until deadline: TimeInterval) -> [Chunk] {
        lock.lock()
        defer { lock.unlock() }
        guard let cut = chunks.firstIndex(where: { $0.time > deadline }) else {
            let all = chunks
            chunks.removeAll()
            return all
        }
        let ready = Array(chunks[..<cut])
        chunks.removeFirst(cut)
        return ready
    }

    /// (overall level, bass level), roughly 0…1, for the glow.
    func meter() -> (Double, Double) {
        lock.lock()
        defer { lock.unlock() }
        return (min(level * 3, 1), min(bass * 4, 1))
    }

    func decay() {
        lock.lock()
        level *= 0.85
        bass *= 0.85
        lock.unlock()
    }
}

// MARK: - MTAudioProcessingTap on AVPlayerItems

/// Per-tap context, owned by the tap (released in `finalize`).
private final class TapContext {
    var sampleRate: Double = 44_100
    var channels: Int = 2
    var isFloat = true
    var isInterleaved = false
    var bitsPerChannel = 32
    var scratch: [Float] = []

    func consume(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0, isFloat || bitsPerChannel == 16 else { return }
        if scratch.count < frames { scratch = [Float](repeating: 0, count: frames) }
        let buffers = Self.buffers(of: list)
        let channelCount = max(channels, 1)

        for f in 0..<frames { scratch[f] = 0 }
        if isInterleaved {
            guard let data = buffers.first?.mData else { return }
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channelCount {
                    let i = f * channelCount + c
                    sum += isFloat ? data.assumingMemoryBound(to: Float.self)[i]
                                   : Float(data.assumingMemoryBound(to: Int16.self)[i]) / 32768
                }
                scratch[f] = sum / Float(channelCount)
            }
        } else {
            let used = min(buffers.count, channelCount)
            guard used > 0 else { return }
            for b in 0..<used {
                guard let data = buffers[b].mData else { continue }
                for f in 0..<frames {
                    scratch[f] += isFloat ? data.assumingMemoryBound(to: Float.self)[f]
                                          : Float(data.assumingMemoryBound(to: Int16.self)[f]) / 32768
                }
            }
            let inv = 1 / Float(used)
            for f in 0..<frames { scratch[f] *= inv }
        }
        scratch.withUnsafeBufferPointer { ptr in
            AmbilightAudioSink.shared.push(UnsafeBufferPointer(rebasing: ptr[0..<frames]), sampleRate: sampleRate)
        }
    }
}

extension TapContext {
    /// The AudioBuffers of an AudioBufferList (variable-length C array after mNumberBuffers),
    /// without depending on the CoreAudio Swift overlay.
    static func buffers(of list: UnsafeMutablePointer<AudioBufferList>) -> UnsafeMutableBufferPointer<AudioBuffer> {
        let count = Int(list.pointee.mNumberBuffers)
        let offset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 8
        let first = (UnsafeMutableRawPointer(list) + offset).assumingMemoryBound(to: AudioBuffer.self)
        return UnsafeMutableBufferPointer(start: first, count: count)
    }
}

private func context(_ tap: MTAudioProcessingTap) -> TapContext {
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let ctx = context(tap)
    let f = format.pointee
    ctx.sampleRate = f.mSampleRate
    ctx.channels = Int(f.mChannelsPerFrame)
    ctx.isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    ctx.isInterleaved = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
    ctx.bitsPerChannel = Int(f.mBitsPerChannel)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    context(tap).consume(bufferListInOut, frames: Int(numberFramesOut.pointee))
}

/// Attaches / detaches the capture tap on the player's items.
@MainActor
enum AmbilightTap {
    /// Every player item gets the tap: it feeds the visualizers, and Ambilight when it's on.
    static var enabled = true

    static func attachIfEnabled(_ item: AVPlayerItem) {
        guard enabled else { return }
        attach(item)
    }

    static func attach(_ item: AVPlayerItem) {
        guard item.audioMix == nil else { return }
        Task { @MainActor in
            // Taps work on progressive streams (Jellyfin direct play / mp3), not on HLS.
            guard enabled, item.audioMix == nil,
                  let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            let ctx = TapContext()
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: Unmanaged.passRetained(ctx).toOpaque(),
                init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: tapUnprepare, process: tapProcess)
            var tap: MTAudioProcessingTap?
            guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                             kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
                  let tap else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
    }

    static func detach(_ item: AVPlayerItem) {
        item.audioMix = nil
    }
}

// MARK: - WebSocket streamer

/// Sends the captured audio to `ws://mac:8787/api/audio`, delayed by the output latency so the
/// lights land exactly with what is heard (AirPods included).
@MainActor
final class AmbilightAudioStreamer {
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var sentRate: Double = 0
    private var backoff: Double = 0.5
    private(set) var isRunning = false

    func start(base: String, token: String) {
        guard !isRunning else { return }
        isRunning = true
        AmbilightAudioSink.shared.setQueueing(true)
        loop = Task { [weak self] in await self?.run(base: base, token: token) }
    }

    func stop() {
        isRunning = false
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        AmbilightAudioSink.shared.setQueueing(false)
    }

    private func outputDelay() -> TimeInterval {
        let s = AVAudioSession.sharedInstance()
        return min(max(s.outputLatency + s.ioBufferDuration, 0), 0.5)
    }

    private func connect(base: String, token: String, rate: Double) -> URLSessionWebSocketTask? {
        let wsBase = base.replacingOccurrences(of: "http://", with: "ws://").replacingOccurrences(of: "https://", with: "wss://")
        var c = URLComponents(string: wsBase + "/api/audio")
        c?.queryItems = [URLQueryItem(name: "sample_rate", value: "\(Int(rate))"),
                         URLQueryItem(name: "name", value: UIDevice.current.name),
                         URLQueryItem(name: "token", value: token)]
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        return task
    }

    private func run(base: String, token: String) async {
        var delay = outputDelay()
        var lastDelayCheck = Date()
        while !Task.isCancelled {
            if Date().timeIntervalSince(lastDelayCheck) > 2 {
                delay = outputDelay()
                lastDelayCheck = Date()
            }
            let due = AmbilightAudioSink.shared.drain(until: ProcessInfo.processInfo.systemUptime - delay)
            if !due.isEmpty {
                do {
                    try await send(due, base: base, token: token)
                    backoff = 0.5
                } catch {
                    // Drop the socket and retry quietly with a growing pause.
                    socket?.cancel(with: .goingAway, reason: nil)
                    socket = nil
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 8)
                    continue
                }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func send(_ chunks: [AmbilightAudioSink.Chunk], base: String, token: String) async throws {
        for chunk in chunks {
            if socket == nil {
                socket = connect(base: base, token: token, rate: chunk.sampleRate)
                sentRate = chunk.sampleRate
            } else if chunk.sampleRate != sentRate {
                try await socket?.send(.string("{\"sample_rate\": \(Int(chunk.sampleRate))}"))
                sentRate = chunk.sampleRate
            }
            guard let socket else { return }
            // ~20 ms per message.
            let step = max(Int(chunk.sampleRate / 50), 160)
            var start = 0
            while start < chunk.samples.count {
                let end = min(start + step, chunk.samples.count)
                let data = chunk.samples[start..<end].withUnsafeBufferPointer { Data(buffer: $0) }
                try await socket.send(.data(data))
                start = end
            }
        }
    }
}
