import AppKit
import ObjectiveC
import SwiftUI

/// The menu bar icon of the Mac app: a small player (cover, title, ⏮ ⏯ ⏭) that stays there when the
/// window is closed, so the app keeps playing and Atoll stays connected. Quit from here or ⌘Q.
@MainActor
@objc(SonalexMenuBarPlugin)
final class MenuBarPlugin: NSObject, MenuBarBridge {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private let model = MenuBarModel()
    private var handler: ((String) -> Void)?

    func start(_ handler: @escaping (String) -> Void) {
        guard item == nil else { return }
        self.handler = handler
        keepRunningWithoutWindows()
        takeOverURLs()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon(playing: false)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarView(model: model) { [weak self] in
            self?.send($0)
        })
    }

    func update(_ info: [String: Any]) {
        let wasPlaying = model.isPlaying
        model.apply(info)
        if wasPlaying != model.isPlaying || item?.button?.image == nil {
            item?.button?.image = Self.icon(playing: model.isPlaying)
        }
        item?.button?.toolTip = model.title.isEmpty ? "Sonalex" : "\(model.title) — \(model.artist)"
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ command: String, _ key: String = "") {
            let entry = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: key)
            entry.target = self
            entry.representedObject = command
            menu.addItem(entry)
        }
        if !model.title.isEmpty {
            let now = NSMenuItem(title: "\(model.title) — \(model.artist)", action: nil, keyEquivalent: "")
            now.isEnabled = false
            menu.addItem(now)
            menu.addItem(.separator())
        }
        add(model.isPlaying ? "Pause" : "Lecture", "playpause")
        add("Suivant", "next")
        add("Précédent", "previous")
        menu.addItem(.separator())
        add("Ouvrir Sonalex", "window")
        add("Quitter Sonalex", "quit", "q")
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil  // left click keeps opening the player
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map(send)
    }

    private func send(_ command: String) {
        switch command {
        case "window":
            popover.performClose(nil)
            NSApp.activate(ignoringOtherApps: true)
            handler?("window")
        case "quit":
            NSApp.terminate(nil)
        default:
            handler?(command)
        }
    }

    // MARK: musique:// links (Atoll…)

    private var otherApp: NSRunningApplication?
    private var activatedAt = Date.distantPast

    /// musique://pause from Atoll used to reopen the window: the link went through SwiftUI, which
    /// needs a window to hand it to (and macOS brought the app forward). Taken here instead: the
    /// command runs with no window, and the app that was in front stays there.
    private func takeOverURLs() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app else { return }
                if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    self.activatedAt = Date()
                } else {
                    self.otherApp = app
                }
            }
        }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let link = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: link), url.scheme == "musique" else { return }
        let command = url.host ?? ""
        handler?(link)
        guard command != "open" else { return }
        // Brought forward just for this link: give the front back to where the user was.
        let previous = otherApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, NSApp.isActive, Date().timeIntervalSince(self.activatedAt) < 1.5 else { return }
                previous?.activate()
            }
        }
    }

    private static func icon(playing: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: playing ? "music.note" : "music.note.list",
                            accessibilityDescription: "Sonalex")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        image?.isTemplate = true
        return image
    }

    /// Closing the window must not quit the app (the music and Atoll's link go on): the Mac app's
    /// delegate (UIKit's) is told to answer "no" to "terminate after last window closed".
    private func keepRunningWithoutWindows() {
        guard let delegate = NSApp.delegate else { return }
        let cls: AnyClass = type(of: delegate)
        let sel = #selector(NSApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed(_:))
        let block: @convention(block) (AnyObject, NSApplication) -> Bool = { _, _ in false }
        let imp = imp_implementationWithBlock(block)
        if !class_addMethod(cls, sel, imp, "B@:@") {
            class_replaceMethod(cls, sel, imp, "B@:@")
        }
    }
}

// MARK: - Model

@MainActor
final class MenuBarModel: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var artwork: NSImage?
    /// Elapsed time at `elapsedAt` (the bar moves on its own while playing).
    @Published var elapsed: Double = 0
    @Published var elapsedAt = Date()
    private var artworkURL = ""

    func apply(_ info: [String: Any]) {
        title = info["title"] as? String ?? ""
        artist = info["artist"] as? String ?? ""
        isPlaying = info["isPlaying"] as? Bool ?? false
        duration = info["duration"] as? Double ?? 0
        elapsed = info["elapsed"] as? Double ?? 0
        elapsedAt = Date()
        let url = info["artworkURL"] as? String ?? ""
        guard url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        guard let u = URL(string: url) else { return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.artworkURL == url else { return }
                    self.artwork = image
                }
            }
        }.resume()
    }

    func position(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        let t = elapsed + (isPlaying ? date.timeIntervalSince(elapsedAt) : 0)
        return min(max(t, 0), duration)
    }
}

// MARK: - Popover

struct MenuBarView: View {
    @ObservedObject var model: MenuBarModel
    let send: (String) -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if let art = model.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.15)
                            Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title.isEmpty ? "Rien en lecture" : model.title)
                        .font(.headline)
                        .lineLimit(2)
                    if !model.artist.isEmpty {
                        Text(model.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if model.duration > 0 {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let t = model.position(at: context.date)
                    VStack(spacing: 4) {
                        ProgressView(value: t, total: model.duration)
                            .progressViewStyle(.linear)
                            .tint(.red)
                        HStack {
                            Text(Self.format(t))
                            Spacer()
                            Text("-" + Self.format(model.duration - t))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 34) {
                control("backward.fill", size: 18) { send("previous") }
                control(model.isPlaying ? "pause.fill" : "play.fill", size: 28) { send("playpause") }
                control("forward.fill", size: 18) { send("next") }
            }
            .disabled(model.title.isEmpty)

            Divider()

            HStack {
                Button("Ouvrir Sonalex") { send("window") }
                Spacer()
                Button("Quitter") { send("quit") }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func format(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
