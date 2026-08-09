import ForerunCore
import Foundation
import Security

// MARK: - Wire types

/// A TickTick project. `color` is optional in practice — it is present in the project-list
/// response and absent from the project sub-object inside `/data` (Spike A).
struct TickTickProject: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String?
    let closed: Bool?
    let kind: String?
}

struct TickTickTask: Decodable, Sendable {
    let id: String
    let projectId: String
    let title: String?
    let content: String?
    let desc: String?
    let isAllDay: Bool?
    let dueDate: String?
    let startDate: String?
    let timeZone: String?
    /// None 0, Low 1, Medium 3, High 5. Two and four are never used.
    let priority: Int?
    let tags: [String]?
    /// Normal 0, Completed 2. Note this differs from `ChecklistItem`, where completed is 1.
    let status: Int?
    let repeatFlag: String?
}

struct TickTickProjectData: Decodable, Sendable {
    let project: TickTickProject?
    /// Undone tasks only. Completed ones need a separate endpoint, which Forerun never calls —
    /// it only cares about upcoming work.
    let tasks: [TickTickTask]?
}

// MARK: - Dates

/// TickTick emits `yyyy-MM-dd'T'HH:mm:ssZ` with a **colonless** offset (`+0000`), and the newer
/// endpoints also emit fractional seconds. `ISO8601DateFormatter` with default options fails on
/// both, so the parser tries every observed shape before giving up.
enum TickTickDate {
    // Formatters are built per parse rather than cached. `ISO8601DateFormatter` and
    // `DateFormatter` are not Sendable, and a shared static instance is a genuine data race the
    // moment two project fetches parse concurrently — which is the normal case here, since the
    // client runs three at a time. Parsing happens a few times per task, not in a hot loop.
    private static var iso: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static var isoFractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static var colonless: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }

    private static var colonlessFractional: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return isoFractional.date(from: string)
            ?? iso.date(from: string)
            ?? colonlessFractional.date(from: string)
            ?? colonless.date(from: string)
    }
}

// MARK: - Token storage

/// The access token, in the Keychain.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the background refresh task needs it
/// while the phone is locked, and `ThisDeviceOnly` keeps it out of iCloud Keychain and off a
/// restored backup — a full-scope, six-month, non-rotatable token should not travel.
actor TickTickTokenStore {
    static let shared = TickTickTokenStore()

    private let service = "com.persueapps.forerun.ticktick"
    private let account = "access-token"

    struct Token: Codable, Sendable {
        let accessToken: String
        let expiresAt: Date?
    }

    private var cached: Token?

    func token() -> Token? {
        if let cached { return cached }
        guard let data = read() else { return nil }
        let token = try? JSONDecoder().decode(Token.self, from: data)
        cached = token
        return token
    }

    /// Spike A: there is **no refresh token**, and observed lifetimes are around six months. A
    /// 401 means re-running the whole authorization flow, roughly twice a year.
    var hasValidToken: Bool {
        guard let token = token() else { return false }
        guard let expiresAt = token.expiresAt else { return true }
        return expiresAt > .now
    }

    func store(accessToken: String, expiresIn: TimeInterval?) {
        let token = Token(
            accessToken: accessToken,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) }
        )
        cached = token
        guard let data = try? JSONEncoder().encode(token) else { return }
        write(data)
    }

    func clear() {
        cached = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private func write(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}

// MARK: - Client

/// Reads projects and their undone tasks.
///
/// The project list is cached for 24 hours and per-project fetches are throttled to three at a
/// time. The rate limit is **undocumented** (Spike A found the widely-repeated "100 req/min"
/// figure to be fabricated), so the client stays deliberately conservative and backs off on
/// 429 and 5xx.
actor TickTickClient {
    static let shared = TickTickClient()

    static let maxConcurrentProjectFetches = 3
    static let projectCacheLifetime: TimeInterval = 24 * 3_600

    private let session: URLSession
    private var cachedProjects: [TickTickProject] = []
    private var projectsFetchedAt: Date?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func invalidateCaches() {
        cachedProjects = []
        projectsFetchedAt = nil
    }

    func projects() async throws -> [TickTickProject] {
        if let projectsFetchedAt,
           Date().timeIntervalSince(projectsFetchedAt) < Self.projectCacheLifetime,
           !cachedProjects.isEmpty {
            return cachedProjects
        }
        let projects: [TickTickProject] = try await get("/open/v1/project")
        cachedProjects = projects.filter { $0.closed != true }
        projectsFetchedAt = .now
        return cachedProjects
    }

    /// N+1 by design — the API offers no bulk task endpoint. Throttled rather than parallelised
    /// flat out, because the real limit is unknown.
    func tasks(in projects: [TickTickProject]) async throws -> [(project: TickTickProject, tasks: [TickTickTask])] {
        var results: [(TickTickProject, [TickTickTask])] = []
        var index = 0

        while index < projects.count {
            let slice = Array(projects[index..<min(index + Self.maxConcurrentProjectFetches, projects.count)])
            index += slice.count

            try await withThrowingTaskGroup(of: (TickTickProject, [TickTickTask]).self) { group in
                for project in slice {
                    group.addTask { [self] in
                        let data: TickTickProjectData = try await get("/open/v1/project/\(project.id)/data")
                        return (project, data.tasks ?? [])
                    }
                }
                for try await result in group {
                    results.append(result)
                }
            }
        }
        return results
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let base = TickTickConfiguration.apiBaseURL,
              let url = URL(string: path, relativeTo: base)
        else { throw EventSourceError.network("Bad TickTick URL") }

        guard let token = await TickTickTokenStore.shared.token()?.accessToken else {
            throw EventSourceError.reauthenticationRequired
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EventSourceError.network("No response")
        }
        switch http.statusCode {
        case 200...299:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw EventSourceError.decoding(String(describing: error))
            }
        case 401, 403:
            // No refresh token exists, so this always means "run the whole flow again."
            await TickTickTokenStore.shared.clear()
            throw EventSourceError.reauthenticationRequired
        case 429:
            throw EventSourceError.network("TickTick is rate limiting. Try again shortly.")
        default:
            throw EventSourceError.network("TickTick returned \(http.statusCode)")
        }
    }
}
