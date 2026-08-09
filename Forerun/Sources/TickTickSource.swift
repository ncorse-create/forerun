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
    static var clientID: String? { TickTickSecrets.clientID }
    static var clientSecret: String? { TickTickSecrets.clientSecret }

    /// An https Universal Link, not a custom scheme. `ASWebAuthenticationSession` intercepts it
    /// before any network request, so the authorization code never reaches a server.
    static var redirectURI: String? { TickTickSecrets.redirectURI }

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

/// Overridden by the gitignored `TickTickCredentials.swift`. Absent credentials are the
/// committed default, deliberately.
enum TickTickSecrets {
    static let clientID: String? = nil
    static let clientSecret: String? = nil
    static let redirectURI: String? = nil
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
