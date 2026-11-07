import Foundation

/// Where the project lives: shown on the login screen and in the profile menu.
enum AppInfo {
    static let name = "Sonalex"
    /// Source code of the app and of the optional Sonalex server.
    static let repository = URL(string: "https://github.com/AlexLeDevDu22/sonalex")!
    static let serverGuide = URL(string: "https://github.com/AlexLeDevDu22/sonalex#le-serveur-sonalex-optionnel")!
    static let privacyPolicy = URL(string: "https://github.com/AlexLeDevDu22/sonalex/blob/main/PRIVACY.md")!
    static let jellyfin = URL(string: "https://jellyfin.org")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
