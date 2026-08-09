import ForerunCore
import Foundation

/// TickTick's client credentials.
///
/// Spike A established that a `client_secret` is mandatory and that PKCE is undocumented, so
/// the secret is embedded and **treated as public** — see `docs/decisions/002-ticktick.md` for
/// why a token-exchange proxy would be worse rather than better.
///
/// The real values live in `TickTickCredentials.swift`, which is gitignored and absent from a
/// fresh clone. When it is absent, `isConfigured` is false and the entire TickTick surface is
/// **hidden** rather than disabled: a credential-free build is a complete, shippable,
/// EventKit-only app with no dead UI in it.
enum TickTickConfiguration {
    static var clientID: String? { TickTickCredentialsProvider.clientID }
    static var clientSecret: String? { TickTickCredentialsProvider.clientSecret }

    /// An https Universal Link, not a custom scheme. `ASWebAuthenticationSession` intercepts it
    /// before any network request, so the authorization code never reaches a server.
    static var redirectURI: String? { TickTickCredentialsProvider.redirectURI }

    static var isConfigured: Bool {
        guard let clientID, let clientSecret, let redirectURI else { return false }
        return !clientID.isEmpty && !clientSecret.isEmpty && !redirectURI.isEmpty
    }

    // OAuth lives on ticktick.com, the API on api.ticktick.com. Split hosts — easy to get wrong.
    static let authorizeURL = URL(string: "https://ticktick.com/oauth/authorize")
    static let tokenURL = URL(string: "https://ticktick.com/oauth/token")
    static let apiBaseURL = URL(string: "https://api.ticktick.com")

    /// Exactly two scopes exist, and they are space-separated. The token request must repeat
    /// them, not just the authorize request.
    static let scope = "tasks:read"
}

/// The default, credential-free provider. `TickTickCredentials.swift` — when present —
/// replaces these by defining the same members in an extension the compiler prefers.
enum TickTickCredentialsProvider {
    static var clientID: String? { TickTickSecrets.clientID }
    static var clientSecret: String? { TickTickSecrets.clientSecret }
    static var redirectURI: String? { TickTickSecrets.redirectURI }
}

/// Overridden by the gitignored `TickTickCredentials.swift`. Absent credentials are the
/// committed default, deliberately.
enum TickTickSecrets {
    static let clientID: String? = nil
    static let clientSecret: String? = nil
    static let redirectURI: String? = nil
}

/// Reads undone TickTick tasks as trackable events. Built out in Sprint 9; the type exists from
/// Sprint 2 so `EventSyncService` has one shape for "a second source" rather than a special
/// case bolted on later.
actor TickTickSource: EventSource {
    nonisolated var displayName: String { "TickTick" }

    nonisolated static var isConfigured: Bool { TickTickConfiguration.isConfigured }

    var isAuthorized: Bool {
        // Sprint 9 replaces this with a Keychain token check. Until then an unconfigured build
        // reports honestly that it has no TickTick access, and sync skips it entirely.
        Self.isConfigured
    }

    func fetchEvents(from start: Date, to end: Date) async throws -> [NormalizedEvent] {
        guard Self.isConfigured else { return [] }
        return []
    }
}
