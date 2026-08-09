import AuthenticationServices
import ForerunCore
import Foundation

/// The OAuth flow.
///
/// Spike A established that a `client_secret` is mandatory and PKCE is undocumented, so the
/// secret is embedded and treated as public (ADR 002). What removes the real risk is the
/// callback: `ASWebAuthenticationSession` intercepts an **https Universal Link** before any
/// network request is made, so the authorization code is delivered to this app by a link only
/// this app can claim, and never reaches a server — including ours. That closes the
/// code-interception hole PKCE would otherwise cover, and it sidesteps the one question the
/// spike could not settle: whether TickTick's registration form accepts a custom scheme at all.
@MainActor
final class TickTickAuth {
    enum AuthError: LocalizedError {
        case notConfigured
        case cancelled
        case noCode
        case exchangeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "TickTick isn't set up in this build."
            case .cancelled:
                nil
            case .noCode:
                "TickTick didn't send back an authorization code."
            case .exchangeFailed(let detail):
                "TickTick wouldn't complete the connection. \(detail)"
            }
        }
    }

    private var session: ASWebAuthenticationSession?
    /// Retained for the lifetime of the sheet; the session holds it weakly.
    private var anchorProvider: AnchorProvider?

    func connect() async throws {
        guard TickTickConfiguration.isConfigured,
              let clientID = TickTickConfiguration.clientID,
              let redirectURI = TickTickConfiguration.redirectURI,
              let authorizeURL = TickTickConfiguration.authorizeURL
        else { throw AuthError.notConfigured }

        // `state` is a nonce that must come back unchanged. Without it, a link that arrives from
        // somewhere other than the flow we started would be honoured.
        let state = UUID().uuidString

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: TickTickConfiguration.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code")
        ]
        guard let url = components?.url else { throw AuthError.notConfigured }

        let callbackURL = try await present(url: url, redirectURI: redirectURI)

        let returned = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems
        guard returned?.first(where: { $0.name == "state" })?.value == state else {
            throw AuthError.noCode
        }
        guard let code = returned?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AuthError.noCode
        }

        try await exchange(code: code, redirectURI: redirectURI)
    }

    private func present(url: URL, redirectURI: String) async throws -> URL {
        guard let redirect = URL(string: redirectURI), let host = redirect.host else {
            throw AuthError.notConfigured
        }
        let path = redirect.path.isEmpty ? "/" : redirect.path

        // Resolved up front so the presentation-context callback never has to guess, and so a
        // genuinely window-less app fails here with a real error rather than presenting into
        // nothing.
        guard let window = Self.resolveWindow() else { throw AuthError.notConfigured }
        let anchorProvider = AnchorProvider(window: window)
        self.anchorProvider = anchorProvider

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .https(host: host, path: path)
            ) { callbackURL, error in
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: cancelled ? AuthError.cancelled : error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AuthError.noCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = anchorProvider
            // The user is signing into a service; reusing the Safari session is what makes that
            // one tap instead of a password.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    /// HTTP Basic, which is what the docs specify. Form-body credentials also work in practice,
    /// but there is no reason to depart from the documented shape.
    private func exchange(code: String, redirectURI: String) async throws {
        guard let tokenURL = TickTickConfiguration.tokenURL,
              let clientID = TickTickConfiguration.clientID,
              let clientSecret = TickTickConfiguration.clientSecret
        else { throw AuthError.notConfigured }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        // `scope` has to be repeated on the token request, not only on authorize — it is in
        // TickTick's own parameter table and is a common cause of a silent failure.
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "scope", value: TickTickConfiguration.scope),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ]
        request.httpBody = body.percentEncodedQuery.map { Data($0.utf8) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.exchangeFailed("Status \(code).")
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Double?
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.exchangeFailed("Unreadable response.")
        }
        // The lifetime comes off the response rather than being assumed. Observed values are
        // around six months, but TickTick publishes no guarantee.
        await TickTickTokenStore.shared.store(
            accessToken: token.access_token,
            expiresIn: token.expires_in
        )
    }

    func disconnect() async {
        await TickTickTokenStore.shared.clear()
        await TickTickClient.shared.invalidateCaches()
    }
}

/// Holds the window the sign-in sheet presents from.
///
/// A separate object so the window can be **non-optional**: every anchor is scene-bound on
/// iOS 26, the parameterless `ASPresentationAnchor()` is deprecated for that reason, and there
/// is no sensible fallback for "no window exists." `TickTickAuth.present` resolves a real
/// window and throws before starting the session, so this is only ever constructed with one.
@MainActor
private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window }
    }
}

@MainActor
extension TickTickAuth {
    /// The foreground window, or nil when the app has none.
    static func resolveWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let window = active?.keyWindow { return window }
        if let window = scenes.flatMap(\.windows).first { return window }
        guard let active else { return nil }
        return UIWindow(windowScene: active)
    }
}
