import ForerunCore
import Foundation

/// TickTick's client credentials.
///
/// Spike A established that a `client_secret` is mandatory and that PKCE is undocumented, so
/// the secret is embedded and **treated as public** — see `docs/decisions/002-ticktick.md` for
/// why a token-exchange proxy would be worse rather than better.
///
/// The real values live in `Forerun/Resources/TickTickCredentials.json`, which is gitignored and
/// absent from a fresh clone. When it is absent, `isConfigured` is false and the entire TickTick
/// surface is **hidden** rather than disabled: a credential-free build is a complete, shippable,
/// EventKit-only app with no dead UI in it.
enum TickTickConfiguration {
    static var clientID: String? { TickTickSecrets.loaded?.clientID }
    static var clientSecret: String? { TickTickSecrets.loaded?.clientSecret }

    /// An https Universal Link, not a custom scheme. `ASWebAuthenticationSession` intercepts it
    /// before any network request, so the authorization code never reaches a server.
    static var redirectURI: String? { TickTickSecrets.loaded?.redirectURI }

    static var isConfigured: Bool {
        guard let clientID, let clientSecret, let redirectURI else { return false }
        return !clientID.isEmpty && !clientSecret.isEmpty && !redirectURI.isEmpty
    }

    // OAuth lives on ticktick.com, the API on api.ticktick.com. Split hosts — easy to get wrong.
    static let authorizeURL = URL(string: "https://ticktick.com/oauth/authorize")
    static let tokenURL = URL(string: "https://ticktick.com/oauth/token")
    static let apiBaseURL = URL(string: "https://api.ticktick.com")

    /// Exactly two scopes exist and they are space-separated. Forerun is read-only in v1, so it
    /// asks for the smaller one — there is no write-back and no completion sync.
    static let scope = "tasks:read"
}

/// Credentials, read at runtime from a gitignored resource.
///
/// This used to be a stub `enum` in this file that a gitignored `TickTickCredentials.swift` was
/// supposed to "override." Swift has no such mechanism — adding the second file produced
/// `invalid redeclaration of 'TickTickSecrets'`, so the documented ship procedure did not
/// compile. Reading a JSON resource removes the compile-time coupling entirely: the credential
/// -free build has no file and no reference to one, and adding the file changes no source.
///
/// Create `Forerun/Resources/TickTickCredentials.json` (gitignored):
/// ```json
/// { "clientID": "…", "clientSecret": "…", "redirectURI": "https://…/oauth" }
/// ```
enum TickTickSecrets {
    struct Values: Decodable, Sendable {
        let clientID: String
        let clientSecret: String
        let redirectURI: String
    }

    static let resourceName = "TickTickCredentials"

    /// Resolved once. A missing file is the normal, committed state and is not an error.
    static let loaded: Values? = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode(Values.self, from: data),
              !values.clientID.isEmpty,
              !values.clientSecret.isEmpty,
              !values.redirectURI.isEmpty
        else { return nil }
        return values
    }()
}

/// How the user's TickTick setup maps onto "red."
///
/// TickTick has no per-task colour, so "auto-track everything red" has to mean something else.
/// Most people do not know their red is a priority flag rather than a colour, which is why the
/// settings screen asks the question in a sentence instead of offering a raw toggle.
struct TickTickRedRule: Sendable, Equatable {
    var treatsHighPriorityAsRed: Bool
    var redProjectIDs: Set<String>

    func matches(priority: Int?, projectID: String) -> Bool {
        if treatsHighPriorityAsRed && priority == 5 { return true }
        return redProjectIDs.contains(projectID)
    }
}

/// Reads undone TickTick tasks as trackable events.
///
/// **The Open API has no calendar surface at all** (Spike A) — no events, no subscribed
/// calendars, no `.ics`. Tasks are all there is. A user whose TickTick usage is calendar-shaped
/// gets more from subscribing their TickTick calendar into Apple Calendar, where Sprint 2
/// already reads it.
actor TickTickSource: EventSource {
    nonisolated var displayName: String { "TickTick" }

    nonisolated static var isConfigured: Bool { TickTickConfiguration.isConfigured }

    private var redRule = TickTickRedRule(treatsHighPriorityAsRed: true, redProjectIDs: [])

    var isAuthorized: Bool {
        get async {
            guard Self.isConfigured else { return false }
            return await TickTickTokenStore.shared.hasValidToken
        }
    }

    func setRedRule(_ rule: TickTickRedRule) {
        redRule = rule
    }

    func availableProjects() async throws -> [TickTickProject] {
        guard Self.isConfigured else { return [] }
        return try await TickTickClient.shared.projects()
    }

    func fetchEvents(from start: Date, to end: Date) async throws -> [NormalizedEvent] {
        guard Self.isConfigured else { return [] }
        guard await TickTickTokenStore.shared.hasValidToken else {
            throw EventSourceError.reauthenticationRequired
        }

        let projects = try await TickTickClient.shared.projects()
        let byProject = try await TickTickClient.shared.tasks(in: projects)

        return byProject.flatMap { project, tasks in
            tasks.compactMap { task in
                normalize(task, project: project, from: start, to: end)
            }
        }
    }

    private func normalize(
        _ task: TickTickTask,
        project: TickTickProject,
        from start: Date,
        to end: Date
    ) -> NormalizedEvent? {
        // Completed tasks are already excluded by the endpoint, but the field is checked anyway
        // in case a future response shape includes them.
        guard task.status != 2 else { return nil }
        guard let title = task.title, !title.isEmpty else { return nil }

        // `dueDate` is the deadline and is what a prep ladder counts back from. `startDate` is
        // only a fallback for tasks scheduled but not due.
        guard let anchor = TickTickDate.parse(task.dueDate) ?? TickTickDate.parse(task.startDate) else {
            // A task with no date has nothing to plan a run-up to.
            return nil
        }
        guard anchor >= start, anchor <= end else { return nil }

        // How an all-day `dueDate` is normalised is **UNKNOWN** (Spike A) — it may be midnight
        // UTC, midnight in the task's own zone, or an exclusive end. Anchoring an all-day task
        // to its date component in its own timezone is correct under every candidate reading,
        // and the engine then applies the user's preferred delivery hour to it.
        let colorFamily = project.color.flatMap(ColorFamily.from(hex:)) ?? .gray

        return NormalizedEvent(
            sourceID: "ticktick|\(task.id)",
            sourceType: .ticktick,
            title: title,
            notes: task.content ?? task.desc,
            startDate: anchor,
            endDate: nil,
            isAllDay: task.isAllDay ?? false,
            location: nil,
            calendarID: project.id,
            calendarName: project.name,
            colorHex: project.color,
            colorFamily: redRule.matches(priority: task.priority, projectID: project.id)
                ? .red
                : colorFamily,
            priority: task.priority,
            hasRecurrenceRules: !(task.repeatFlag ?? "").isEmpty
        )
    }
}
