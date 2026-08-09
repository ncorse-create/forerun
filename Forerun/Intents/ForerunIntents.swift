import AppIntents
import ForerunCore
import Foundation
import SwiftData

/// "What do I owe my team this week?"
///
/// The highest-value surface this app can have outside itself: a spoken question that answers
/// with the specific sentences, in order, without opening anything. It also gets Spotlight and
/// the Action button for free.
struct WhatDoIOweIntent: AppIntent {
    static let title: LocalizedStringResource = "What I owe this week"
    static let description = IntentDescription(
        "Reads out the prep steps due in the next seven days.",
        categoryName: "Forerun"
    )
    /// Answers in place. Opening the app to read a list defeats the point of asking.
    static let openAppWhenRun = false

    @Parameter(title: "Who for", default: .everyone)
    var audience: IntentAudience

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let container = try ForerunStore.container()
        let context = ModelContext(container)
        let steps = IntentQueries.stepsDue(within: 7, audience: audience, context: context)

        guard !steps.isEmpty else {
            return .result(
                dialog: IntentDialog(audience == .everyone
                    ? "Nothing due this week."
                    : "Nothing due for your \(audience.spokenName) this week."),
                view: IntentStepsView(rows: [])
            )
        }

        let spoken = steps.prefix(5).map(\.copy).joined(separator: ". ")
        let more = steps.count > 5 ? " And \(steps.count - 5) more." : ""
        return .result(
            dialog: IntentDialog("\(spoken).\(more)"),
            view: IntentStepsView(rows: steps)
        )
    }
}

/// The next single thing, for a glance rather than a list.
struct NextStepIntent: AppIntent {
    static let title: LocalizedStringResource = "My next prep step"
    static let description = IntentDescription(
        "Reads out the next thing Forerun is waiting on.",
        categoryName: "Forerun"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try ForerunStore.container()
        let context = ModelContext(container)
        guard let next = IntentQueries.stepsDue(within: 60, audience: .everyone, context: context).first else {
            return .result(dialog: IntentDialog("Nothing needs you yet."))
        }
        return .result(dialog: IntentDialog("\(next.copy) — for \(next.eventTitle), \(next.whenLabel)."))
    }
}

/// Marks the next step done without opening anything.
struct MarkNextStepDoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark my next prep step done"
    static let description = IntentDescription(
        "Marks the next prep step as done.",
        categoryName: "Forerun"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try ForerunStore.container()
        let context = ModelContext(container)
        guard let next = IntentQueries.nextSchedulableStep(context: context) else {
            return .result(dialog: IntentDialog("There's nothing waiting."))
        }

        let copy = next.effectiveCopy
        next.state = .done
        if !next.isCustom {
            context.insert(StepOutcome(
                playbookStepID: next.playbookStepID,
                kind: next.plan?.event?.kind ?? .unknown,
                audience: next.audience,
                offsetSeconds: next.offsetSeconds,
                state: .done,
                fromNotification: false
            ))
        }
        try? context.save()

        return .result(dialog: IntentDialog("Marked done: \(copy)"))
    }
}

// MARK: - Parameters

enum IntentAudience: String, AppEnum {
    case everyone
    case leaders
    case participants

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Audience")

    static let caseDisplayRepresentations: [IntentAudience: DisplayRepresentation] = [
        .everyone: "Everyone",
        .leaders: "Leaders",
        .participants: "Participants"
    ]

    var spokenName: String {
        switch self {
        case .everyone: "team"
        case .leaders: "leaders"
        case .participants: "participants"
        }
    }

    func matches(_ audience: Audience) -> Bool {
        switch self {
        case .everyone: true
        case .leaders: audience.isLeadership
        case .participants: audience.isAudienceSide
        }
    }
}

// MARK: - Queries

struct IntentStepRow: Identifiable, Sendable {
    let id: UUID
    let copy: String
    let eventTitle: String
    let fireDate: Date
    let audience: Audience

    var whenLabel: String {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: .now),
            to: Calendar.current.startOfDay(for: fireDate)
        ).day ?? 0
        switch days {
        case ..<0: return "overdue"
        case 0: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }
}

enum IntentQueries {
    /// Opens its own container rather than reaching for the app's.
    ///
    /// An intent can run while the app is not, so there is no `AppEnvironment` to borrow. Both
    /// point at the same on-disk store, and writes are saved immediately so the app picks them
    /// up on its next foreground.
    @MainActor
    static func stepsDue(
        within days: Int,
        audience: IntentAudience,
        context: ModelContext
    ) -> [IntentStepRow] {
        let horizon = Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now
        let events = (try? context.fetch(FetchDescriptor<TrackedEvent>())) ?? []

        return events
            .filter { $0.disappearedAt == nil && !$0.isDuplicate }
            .flatMap { event -> [IntentStepRow] in
                guard let plan = event.plan else { return [] }
                return plan.steps.compactMap { step in
                    guard step.state.isSchedulable || step.state == .fired else { return nil }
                    guard audience.matches(step.audience) else { return nil }
                    let fireDate = step.snoozedUntil ?? step.fireDate
                    guard fireDate <= horizon else { return nil }
                    return IntentStepRow(
                        id: step.id,
                        copy: step.effectiveCopy,
                        eventTitle: event.title,
                        fireDate: fireDate,
                        audience: step.audience
                    )
                }
            }
            .sorted { $0.fireDate < $1.fireDate }
    }

    @MainActor
    static func nextSchedulableStep(context: ModelContext) -> PrepStep? {
        let events = (try? context.fetch(FetchDescriptor<TrackedEvent>())) ?? []
        return events
            .filter { $0.disappearedAt == nil && !$0.isDuplicate }
            .compactMap(\.plan)
            .flatMap(\.steps)
            .filter { $0.state.isSchedulable || $0.state == .fired }
            .min { ($0.snoozedUntil ?? $0.fireDate) < ($1.snoozedUntil ?? $1.fireDate) }
    }
}

// MARK: - Shortcuts

struct ForerunShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatDoIOweIntent(),
            phrases: [
                "What do I owe my team in \(.applicationName)",
                "What's due this week in \(.applicationName)",
                "\(.applicationName) this week"
            ],
            shortTitle: "What I owe this week",
            systemImageName: "list.bullet.rectangle"
        )
        AppShortcut(
            intent: NextStepIntent(),
            phrases: [
                "What's my next step in \(.applicationName)",
                "\(.applicationName) next step"
            ],
            shortTitle: "My next prep step",
            systemImageName: "arrow.forward.circle"
        )
        AppShortcut(
            intent: MarkNextStepDoneIntent(),
            phrases: [
                "Mark my next step done in \(.applicationName)",
                "\(.applicationName) mark done"
            ],
            shortTitle: "Mark next step done",
            systemImageName: "checkmark.circle"
        )
    }
}
