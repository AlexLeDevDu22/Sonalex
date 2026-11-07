import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Connects the user's Spotify account to their library on the server: Spotify's own sign-in page
/// (Authorization Code with PKCE, through the server owner's Spotify app: no secret on the phone),
/// then the server keeps the token and syncs likes and playlists (backend/spotify_auth.py).
@MainActor
final class SpotifyConnect: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SpotifyConnect()

    private var session: ASWebAuthenticationSession?

    private struct Config: Decodable {
        var clientId: String
        var redirectUri: String
        var scopes: String
    }

    private struct Connected: Decodable {
        var id: String
        var name: String
    }

    enum Failure: LocalizedError {
        case cancelled, refused(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: "Spotify sign-in cancelled."
            case .refused(let reason): reason
            }
        }
    }

    /// Returns the Spotify account's name.
    func connect() async throws -> String {
        let config: Config = try await SonalexAPI.shared.fetch("/api/me/spotify")
        let verifier = Self.randomString(64)
        let state = Self.randomString(16)
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectUri),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "scope", value: config.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = c.url, let scheme = URL(string: config.redirectUri)?.scheme else { throw APIError.badURL }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: Failure.cancelled)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: Failure.cancelled) }
        }
        session = nil
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw Failure.refused(error == "access_denied" ? "Spotify sign-in refused." : "Spotify: \(error)")
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else { throw Failure.cancelled }
        let data = try await SonalexAPI.shared.send("/api/me/spotify", method: "POST", body: [
            "code": code, "verifier": verifier, "redirectUri": config.redirectUri,
        ], timeout: 40)
        return (try? JellyfinClient.decoder.decode(Connected.self, from: data))?.name ?? "Spotify"
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? UIWindow()
        }
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
