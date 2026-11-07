import Foundation

/// Navigation events sent to the Pi (same log as the player: logs/player-debug.log), to find out
/// why pages don't open on the Mac. Remove once fixed.
@MainActor
enum NavDiagnostics {
    static func log(_ event: String, _ info: [String: Any] = [:]) {
        PlayerDiagnostics.log("nav." + event, info)
    }
}
