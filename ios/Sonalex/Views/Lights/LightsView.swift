import SwiftUI

/// "Lumières": drives the Ambilight LED strip and mouse running on the Mac.
struct LightsView: View {
    @Environment(AmbilightClient.self) private var ambi
    @Environment(PlayerManager.self) private var player
    @State private var showSettings = false
    @State private var choosingMac = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var wide: Bool { sizeClass == .regular }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let banner = ambi.remoteBanner {
                    Label(banner, systemImage: "appletvremote.gen4.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if choosingMac || ambi.base == nil {
                    DiscoveryView { choosingMac = false }
                        .frame(maxWidth: 560)
                } else if !ambi.reachable {
                    offlineCard
                        .frame(maxWidth: 560)
                } else if !ambi.isPaired {
                    PairingView()
                        .frame(maxWidth: 560)
                } else {
                    controls
                }
            }
            // Wide screens: two columns, never wider than ~1100 pt, centered.
            .frame(maxWidth: wide ? 1100 : .infinity)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, wide ? 28 : 20)
            .padding(.top, wide ? 12 : 4)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Lumières")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ConnectionPill()
                if ambi.isPaired {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            LightsSettingsSheet(chooseAnotherMac: { choosingMac = true })
                .appEnvironment()
        }
        .onAppear { ambi.startEvents() }
        .onDisappear { ambi.stopEvents() }
        .task(id: ambi.isPaired) { if ambi.isPaired { await ambi.reloadState() } }
    }

    // MARK: Paired controls

    @ViewBuilder private var controls: some View {
        if ambi.live?.sleep?.on == true {
            Label("Ton Mac est en veille — les lumières reviendront toutes seules.", systemImage: "moon.zzz.fill")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.indigo.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        if wide {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 18) {
                    heroCard
                    musicCard
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 18) {
                    stripSection
                    MouseSection()
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            heroCard
            musicCard
            stripSection
            MouseSection()
        }
    }

    private var heroCard: some View {
        let on = ambi.isOn
        let palette = (ambi.live?.leds?.palette ?? []).map { Color(ambiHex: $0) }
        return VStack(spacing: 14) {
            LEDStripPreview(preview: ambi.live?.leds?.preview, running: ambi.live?.leds?.running ?? false)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            HStack(alignment: .center) {
                MousePreview(preview: ambi.live?.mouse?.preview, running: ambi.live?.mouse?.running ?? false)
                VStack(alignment: .leading, spacing: 3) {
                    Text(on ? "Allumées" : "Éteintes").font(.headline)
                    Text(ambi.live?.leds?.status ?? ambi.macName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.leading, 10)
                Spacer()
                Button { ambi.power(!on) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(width: 72, height: 72)
                        .background {
                            if on, palette.count > 1 {
                                Circle().fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
                            } else {
                                Circle().fill(on ? Color.appAccent : Color(.tertiarySystemFill))
                            }
                        }
                        .shadow(color: (palette.first ?? .appAccent).opacity(on ? 0.6 : 0), radius: 16)
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                .sensoryFeedback(.impact(weight: .medium), trigger: on)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: on)
    }

    private var musicCard: some View {
        LightsCard {
            Toggle(isOn: Binding(get: { ambi.musicActive }, set: { ambi.setMusicMode($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Lumières sur la musique", systemImage: "waveform")
                        .font(.headline)
                    Text("Les lumières suivent ce que joue l’app, aux couleurs de la pochette.")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.55))
                }
            }
            .tint(.appAccent)
            .sensoryFeedback(.selection, trigger: ambi.musicActive)

            if ambi.musicActive, let track = player.current {
                HStack(spacing: 10) {
                    ArtworkView(item: track, points: 34, cornerRadius: 5).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ambi.isStreamingMusic ? "Synchronisé avec" : "En pause")
                            .font(.caption2)
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("\(track.title) – \(track.artistLine)")
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                    }
                    Spacer()
                    LevelBars(levels: ambi.isStreamingMusic ? (ambi.live?.levels ?? []) : [], color: .appAccent)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: ambi.musicActive)
    }

    // MARK: Strip

    @ViewBuilder private var stripSection: some View {
        let mode = ambi.config?.leds?.mode ?? "sound"
        LightsCard {
            Text("Ruban").font(.title3.bold())

            if let modes = ambi.catalog?.leds?.modes, !modes.isEmpty {
                Picker("Mode", selection: Binding(get: { mode }, set: { ambi.setLedMode($0) })) {
                    ForEach(modes) { m in Text(m.id == "sound" ? "Musique" : m.title).tag(m.id) }
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: mode)
            }

            effectChips(mode: mode)

            if mode == "color" {
                colorPickers
            }

            if mode != "screen" && mode != "color", let palettes = ambi.catalog?.palettes, !palettes.isEmpty {
                let selected = ambi.config?.leds?.palette ?? "cover"
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(palettes) { p in
                            Button { ambi.setPalette(p.id) } label: {
                                PaletteSwatch(palette: p, selected: p.id == selected, cover: player.current)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .sensoryFeedback(.selection, trigger: selected)
            }

            HStack(spacing: 12) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: Binding(get: { ambi.config?.leds?.brightness ?? 1 }, set: { ambi.setBrightness($0) }),
                       in: 0.05...1)
                    .tint(.appAccent)
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func effectChips(mode: String) -> some View {
        let effects: [AmbiOption] = mode == "sound" ? (ambi.catalog?.leds?.soundEffects ?? [])
            : mode == "ambient" ? (ambi.catalog?.leds?.ambientEffects ?? []) : []
        let selected = mode == "sound" ? ambi.config?.leds?.soundEffect : ambi.config?.leds?.ambientEffect
        if !effects.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(effects) { e in
                        EffectChip(title: e.title, selected: e.id == selected) { ambi.setLedEffect(e.id) }
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selected)
        }
    }

    private var colorPickers: some View {
        let colors = ambi.config?.leds?.colors ?? ["#ff4d6d", "#7b5cff"]
        let bottom = colors.first ?? "#ff4d6d"
        let top = colors.count > 1 ? colors[1] : bottom
        return HStack(spacing: 24) {
            ColorPicker("Bas", selection: Binding(get: { Color(ambiHex: bottom) },
                                                  set: { ambi.setLedColors([$0.ambiHex, top]) }),
                        supportsOpacity: false)
            ColorPicker("Haut", selection: Binding(get: { Color(ambiHex: top) },
                                                   set: { ambi.setLedColors([bottom, $0.ambiHex]) }),
                        supportsOpacity: false)
        }
        .font(.subheadline.weight(.medium))
    }

    // MARK: Offline

    private var offlineCard: some View {
        LightsCard {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ambi.macName) ne répond pas").font(.headline)
                    Text("Vérifie que le Mac est allumé, sur le même Wi-Fi, et que Ambilight tourne.")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.55))
                }
            }
            HStack {
                Button("Réessayer") { ambi.retry() }
                    .buttonStyle(.borderedProminent)
                    .tint(.appAccent)
                Button("Autre Mac") { choosingMac = true }
                    .buttonStyle(.bordered)
            }
        }
        .opacity(0.85)
    }
}

// MARK: - Mouse

private struct MouseSection: View {
    @Environment(AmbilightClient.self) private var ambi
    @State private var expanded = false

    var body: some View {
        LightsCard {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Allumée", isOn: Binding(get: { ambi.live?.mouse?.running ?? false },
                                                    set: { _ in ambi.toggleMouse() }))
                        .tint(.appAccent)
                    if let modes = ambi.catalog?.mouse?.modes, !modes.isEmpty {
                        Picker("Mode", selection: Binding(get: { ambi.config?.mouse?.mode ?? "sound" },
                                                          set: { ambi.setMouseMode($0) })) {
                            ForEach(modes) { m in Text(m.id == "sound" ? "Musique" : m.title).tag(m.id) }
                        }
                        .tint(.appAccent)
                    }
                    if ambi.config?.mouse?.mode == "sound", let effects = ambi.catalog?.mouse?.soundEffects, !effects.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(effects) { e in
                                EffectChip(title: e.title, selected: e.id == ambi.config?.mouse?.soundEffect) {
                                    ambi.setMouseEffect(e.id)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 12)
            } label: {
                Label("Souris", systemImage: "computermouse.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .tint(.secondary)
        }
        .sensoryFeedback(.selection, trigger: ambi.config?.mouse?.mode)
    }
}

// MARK: - Discovery & pairing

private struct DiscoveryView: View {
    let done: () -> Void
    @Environment(AmbilightClient.self) private var ambi
    @State private var manual = ""
    @State private var connecting: String? = nil
    @State private var error: String? = nil

    var body: some View {
        LightsCard {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recherche de ton Mac…").font(.headline)
                    Text("Le Mac et l’iPhone doivent être sur le même Wi-Fi.")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.55))
                }
            }
            ForEach(ambi.discovered) { found in
                Button {
                    connect(found.name) { await ambi.connect(to: found) }
                } label: {
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text(found.name).lineLimit(1)
                        Spacer()
                        if connecting == found.name { ProgressView() } else { Image(systemName: "chevron.right") }
                    }
                    .padding(14)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        LightsCard {
            Text("Adresse du Mac").font(.headline)
            Text("Affichée sur le Mac dans Réglages avancés › Appareils connectés.")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.55))
            HStack {
                TextField("192.168.1.25:8787", text: $manual)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("OK") {
                    connect("manual") { await ambi.connectManually(manual) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.appAccent)
                .disabled(manual.isEmpty || connecting != nil)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func connect(_ id: String, _ action: @escaping () async -> Bool) {
        connecting = id
        error = nil
        Task {
            if await action() { done() } else { error = "Impossible de joindre ce Mac." }
            connecting = nil
        }
    }
}

private struct PairingView: View {
    @Environment(AmbilightClient.self) private var ambi
    @State private var code = ""
    @State private var waitingCode = false
    @State private var busy = false
    @State private var error: String? = nil
    @FocusState private var focused: Bool

    var body: some View {
        LightsCard {
            VStack(spacing: 16) {
                Image(systemName: "lightbulb.led.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(LinearGradient(colors: [.pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(waitingCode ? "Tape le code affiché sur ton Mac" : "Associer cet iPhone à \(ambi.macName)")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text(waitingCode ? "Un code vient de s’afficher sur ton Mac." : "Un code à 4 chiffres va s’afficher sur le Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary.opacity(0.6))
                    .multilineTextAlignment(.center)

                if waitingCode {
                    codeBoxes
                } else {
                    Button { start() } label: {
                        Group {
                            if busy { ProgressView().tint(.white) } else { Text("Associer").font(.headline) }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(.white)
                        .background(Color.appAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                if waitingCode {
                    Button("Recevoir un nouveau code") { start() }
                        .font(.footnote)
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var codeBoxes: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .opacity(0.02)
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(4))
                    if digits != new { code = digits }
                    if digits.count == 4 { confirm(digits) }
                }
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { i in
                    let chars = Array(code)
                    Text(i < chars.count ? String(chars[i]) : "")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .frame(width: 56, height: 68)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(i == chars.count && focused ? Color.primary.opacity(0.6) : .clear, lineWidth: 2))
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
    }

    private func start() {
        busy = true
        error = nil
        Task {
            do {
                try await ambi.beginPairing()
                code = ""
                waitingCode = true
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func confirm(_ digits: String) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                try await ambi.confirmPairing(code: digits)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = error.localizedDescription
                code = ""
            }
            busy = false
        }
    }
}

// MARK: - Settings

private struct LightsSettingsSheet: View {
    let chooseAnotherMac: () -> Void
    @Environment(AmbilightClient.self) private var ambi
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text("Sensibilité à la musique")
                        Slider(value: Binding(get: { ambi.config?.leds?.sensitivity ?? 1 }, set: { ambi.setSensitivity($0) }),
                               in: 0.3...2.5)
                    }
                    VStack(alignment: .leading) {
                        Text("Vitesse des ambiances")
                        Slider(value: Binding(get: { ambi.config?.leds?.speed ?? 0.5 }, set: { ambi.setSpeed($0) }), in: 0...1)
                    }
                }
                Section("Mac connecté") {
                    LabeledContent("Nom", value: ambi.macName)
                    LabeledContent("Adresse", value: ambi.base?.replacingOccurrences(of: "http://", with: "") ?? "—")
                    Button("Se connecter à un autre Mac") {
                        chooseAnotherMac()
                        dismiss()
                    }
                    Button("Oublier ce Mac", role: .destructive) { confirmForget = true }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .confirmationDialog("Oublier \(ambi.macName) ?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Oublier ce Mac", role: .destructive) {
                    ambi.forget()
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
