import SwiftUI

/// Opens the list of devices to play on (shown only when another device is connected).
struct DevicePickerButton: View {
    var tint: Color = .white.opacity(0.75)
    @State private var showPicker = false

    private var connect: ConnectManager { .shared }

    var body: some View {
        if connect.hasOtherDevices {
            Button { showPicker = true } label: {
                Image(systemName: connect.isRemote ? "hifispeaker.fill" : "laptopcomputer.and.iphone")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(connect.isRemote ? Color.appAccent : tint)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.88))
            .sheet(isPresented: $showPicker) {
                DevicePickerSheet()
                    .appEnvironment()
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

struct DevicePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var connect: ConnectManager { .shared }

    private var sortedDevices: [ConnectManager.Device] {
        connect.devices.sorted { a, b in
            if a.id == connect.myId { return true }
            if b.id == connect.myId { return false }
            return a.name < b.name
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sortedDevices) { device in
                        Button {
                            if device.id != connect.activeId { connect.transfer(to: device.id) }
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: device.systemImage)
                                    .font(.title2)
                                    .frame(width: 36)
                                    .foregroundStyle(device.id == connect.activeId ? Color.appAccent : .primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.id == connect.myId ? "This Device" : device.name)
                                        .foregroundStyle(.primary)
                                    if device.id == connect.myId {
                                        Text(device.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if device.id == connect.activeId {
                                        Label("Now Playing", systemImage: "waveform")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.appAccent)
                                    }
                                }
                                Spacer()
                                if device.id == connect.activeId {
                                    Image(systemName: "checkmark").foregroundStyle(Color.appAccent)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Play On")
                } footer: {
                    Text("Your devices signed in to Sonalex: playback moves from one to another at the same point in the song, and each one can control the one playing.")
                }

                #if !targetEnvironment(macCatalyst)
                Section("This Device’s Audio Output") {
                    HStack(spacing: 14) {
                        AirPlayButton()
                            .frame(width: 36, height: 36)
                        Text("AirPlay & Bluetooth")
                    }
                }
                #endif
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
    }
}

/// "Lecture sur MacBook…" pill, shown while this device remote-controls another one.
struct RemotePlaybackBadge: View {
    var color: Color = .appAccent
    private var connect: ConnectManager { .shared }

    var body: some View {
        if connect.isRemote, let device = connect.activeDevice {
            Label("Playing on \(device.name)", systemImage: device.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}
