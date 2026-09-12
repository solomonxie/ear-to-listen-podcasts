import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct SpotifyToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

enum SpotifyImportError: Error {
    case missingClientID
    case authenticationCancelled
    case invalidCallback
    case tokenExchangeFailed
    case notAuthenticated
    case requestFailed(Int)
}

final class SpotifyImportSource: PlaylistImportSource, @unchecked Sendable {
    static let providerType = "spotify"
    let type = SpotifyImportSource.providerType

    private static let redirectURI = "byomusic://spotify-callback"
    private static let scopes = "playlist-read-private playlist-read-collaborative"
    static let clientIDKey = "spotify.clientID"
    private static let tokenKey = "spotify.token"

    private let credentials = CredentialStore()
    private var authSession: ASWebAuthenticationSession?
    private var presentationContext: WebAuthPresentationContext?

    func isAuthenticated() async -> Bool {
        (try? credentials.getJSON(SpotifyToken.self, forKey: Self.tokenKey)) != nil
    }

    func authenticate() async throws {
        guard let clientID = try credentials.get(Self.clientIDKey), !clientID.isEmpty else {
            throw SpotifyImportError.missingClientID
        }

        let verifier = Self.randomCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes),
        ]
        guard let authURL = components.url else { throw SpotifyImportError.invalidCallback }

        let callbackURL = try await performAuthSession(url: authURL)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SpotifyImportError.invalidCallback
        }

        try await exchangeCode(code, clientID: clientID, verifier: verifier)
    }

    func signOut() async {
        try? credentials.delete(Self.tokenKey)
    }

    func listPlaylists() async throws -> [ImportedPlaylist] {
        struct Response: Decodable {
            struct Item: Decodable {
                let id: String
                let name: String
                let tracks: Tracks
            }
            struct Tracks: Decodable { let total: Int }
            let items: [Item]
            let next: String?
        }

        var playlists: [ImportedPlaylist] = []
        var url = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")
        while let current = url {
            let response: Response = try await get(current)
            playlists += response.items.map { ImportedPlaylist(id: $0.id, name: $0.name, trackCount: $0.tracks.total) }
            url = response.next.flatMap(URL.init(string:))
        }
        return playlists
    }

    func tracks(forPlaylistID playlistID: String) async throws -> [ImportedTrack] {
        struct Response: Decodable {
            struct Item: Decodable { let track: SpotifyTrack? }
            struct SpotifyTrack: Decodable {
                let name: String
                let durationMs: Int
                let album: SpotifyAlbum?
                let artists: [SpotifyArtist]
                enum CodingKeys: String, CodingKey {
                    case name, album, artists
                    case durationMs = "duration_ms"
                }
            }
            struct SpotifyAlbum: Decodable { let name: String }
            struct SpotifyArtist: Decodable { let name: String }
            let items: [Item]
            let next: String?
        }

        var tracks: [ImportedTrack] = []
        var url = URL(string: "https://api.spotify.com/v1/playlists/\(playlistID)/tracks?limit=100")
        while let current = url {
            let response: Response = try await get(current)
            for item in response.items {
                guard let track = item.track else { continue }
                tracks.append(ImportedTrack(
                    title: track.name,
                    artist: track.artists.first?.name ?? "",
                    album: track.album?.name,
                    durationMs: track.durationMs,
                    isrc: nil
                ))
            }
            url = response.next.flatMap(URL.init(string:))
        }
        return tracks
    }

    // MARK: - Auth session

    private func performAuthSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let context = WebAuthPresentationContext()
            presentationContext = context
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "byomusic") { [weak self] callbackURL, error in
                self?.authSession = nil
                self?.presentationContext = nil
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? SpotifyImportError.authenticationCancelled)
                }
            }
            session.presentationContextProvider = context
            session.prefersEphemeralWebBrowserSession = true
            authSession = session
            session.start()
        }
    }

    // MARK: - Token management

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let token = try await validAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpotifyImportError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func validAccessToken() async throws -> String {
        guard var token = try credentials.getJSON(SpotifyToken.self, forKey: Self.tokenKey) else {
            throw SpotifyImportError.notAuthenticated
        }
        if token.expiresAt > Date() {
            return token.accessToken
        }
        guard let refreshToken = token.refreshToken, let clientID = try credentials.get(Self.clientIDKey) else {
            throw SpotifyImportError.notAuthenticated
        }
        token = try await refresh(refreshToken: refreshToken, clientID: clientID)
        try credentials.setJSON(token, forKey: Self.tokenKey)
        return token.accessToken
    }

    private func exchangeCode(_ code: String, clientID: String, verifier: String) async throws {
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        let data = try await tokenRequest(body: body)
        let token = try Self.decodeTokenResponse(data)
        try credentials.setJSON(token, forKey: Self.tokenKey)
    }

    private func refresh(refreshToken: String, clientID: String) async throws -> SpotifyToken {
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        let data = try await tokenRequest(body: body)
        return try Self.decodeTokenResponse(data, fallbackRefreshToken: refreshToken)
    }

    private func tokenRequest(body: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpotifyImportError.tokenExchangeFailed
        }
        return data
    }

    private static func decodeTokenResponse(_ data: Data, fallbackRefreshToken: String? = nil) throws -> SpotifyToken {
        struct Response: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return SpotifyToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? fallbackRefreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn - 60))
        )
    }

    // MARK: - PKCE helpers

    private static func formEncode(_ params: [String: String]) -> Data {
        params.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    private static func randomCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hash))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated override init() {
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
