import Foundation

/// Between the Mac app (Mac Catalyst: UIKit, no access to the menu bar) and its AppKit plug-in
/// SonalexMenuBar.bundle, which owns the menu bar icon. Compiled into both.
@MainActor
@objc(SonalexMenuBarBridge)
public protocol MenuBarBridge: NSObjectProtocol {
    /// Shows the icon. `handler` gets the commands: playpause, next, previous, window (show the
    /// app), or a whole musique:// link (taken by the plug-in so that it doesn't open a window).
    func start(_ handler: @escaping (String) -> Void)
    /// title, artist, artworkURL (String), isPlaying (Bool), elapsed, duration (Double, seconds).
    func update(_ info: [String: Any])
}
