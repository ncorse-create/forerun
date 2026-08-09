import Foundation
import SwiftData

/// Everything Forerun holds about one event, in a shape a human can read.
///
/// The export is JSON rather than the SwiftData store because the point is portability, not
/// backup: it should be openable in any text editor and survive the app being deleted. Photo
/// data is deliberately **not** included — it would balloon the file and the images are already
/// in the user's photo library if they came from there.
public struct EventExport: Codable, Sendable {
    public struct Step: Codable, Sendable {
        public var order: Int
        public var firesAt: Date
        public var relative: String
        public var audience: String
        public var verb: String
        public var copy: String
        public var wasEditedByYou: Bool
        public var timeIsPinned: Bool
        public var state: String
        public var handedOffAt: Date?
    }

    public struct Note: Codable, Sendable {
        public var kind: String
        public var text: String
        public var url: String?
        public var hasPhoto: Bool
        public var createdAt: Date
    }

    public var title: String
    /// The event's own notes, from the calendar. Distinct from `material`, which is what the
    /// user attached in Forerun.
    public var calendarNotes: String?
    public var location: String?
    public var startsAt: Date
    public var endsAt: Date?
    public var isAllDay: Bool
    public var calendar: String
    public var source: String
    public var kind: String
    public var kindConfidence: Double
    public var kindConfirmedByYou: Bool
    public var trackedAt: Date
    public var playbook: String?
    public var wasCompressed: Bool
    public var steps: [Step]
    /// The scratchpad — notes, links and photo captions the user attached in Forerun.
    public var material: [Note]
    public var people: [String]
}

public struct ForerunExport: Codable, Sendable {
    public var exportedAt: Date
    public var appVersion: String
    public var events: [EventExport]
    /// Included because `deleteAll` removes them: without this, "export everything" followed by
    /// "delete everything" permanently lost the skip-rate history the diagnostic is built on.
    public var outcomes: [OutcomeExport]
    public var settings: SettingsExport

    public struct OutcomeExport: Codable, Sendable {
        public var playbookStepID: String
        public var kind: String
        public var audience: String
        public var state: String
        public var decidedAt: Date
        public var fromNotification: Bool
    }

    public struct SettingsExport: Codable, Sendable {
        public var quietHoursStart: Int
        public var quietHoursEnd: Int
        public var dailyNotificationBudget: Int
        public var maxStepsPerEvent: Int
        public var preferredDeliveryHour: Int
        public var trackedCalendarIDs: [String]
        public var autoTrackColorFamilies: [String]
        public var enabledKinds: [String]
    }
}

public enum DataExporter {

    @MainActor
    public static func export(
        from context: ModelContext,
        settings: AppSettings,
        appVersion: String,
        now: Date = .now
    ) throws -> Data {
        let events = (try? context.fetch(FetchDescriptor<TrackedEvent>())) ?? []

        let payload = ForerunExport(
            exportedAt: now,
            appVersion: appVersion,
            events: events
                .sorted { $0.startDate < $1.startDate }
                .map(exportEvent(_:)),
            outcomes: ((try? context.fetch(FetchDescriptor<StepOutcome>())) ?? [])
                .sorted { $0.decidedAt < $1.decidedAt }
                .map { outcome in
                    ForerunExport.OutcomeExport(
                        playbookStepID: outcome.playbookStepID,
                        kind: outcome.kind.rawValue,
                        audience: outcome.audience.rawValue,
                        state: outcome.state.rawValue,
                        decidedAt: outcome.decidedAt,
                        fromNotification: outcome.fromNotification
                    )
                },
            settings: ForerunExport.SettingsExport(
                quietHoursStart: settings.quietHoursStart,
                quietHoursEnd: settings.quietHoursEnd,
                dailyNotificationBudget: settings.dailyNotificationBudget,
                maxStepsPerEvent: settings.maxStepsPerEvent,
                preferredDeliveryHour: settings.preferredDeliveryHour,
                trackedCalendarIDs: settings.trackedCalendarIDs,
                autoTrackColorFamilies: settings.autoTrackColorFamilies,
                enabledKinds: settings.enabledKinds
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    @MainActor
    private static func exportEvent(_ event: TrackedEvent) -> EventExport {
        EventExport(
            title: event.title,
            calendarNotes: event.notes,
            location: event.location,
            startsAt: event.startDate,
            endsAt: event.endDate,
            isAllDay: event.isAllDay,
            calendar: event.calendarName,
            source: event.sourceType.displayName,
            kind: event.kind.displayName,
            kindConfidence: event.kindConfidence,
            kindConfirmedByYou: event.kindWasConfirmedByUser,
            trackedAt: event.trackedAt,
            playbook: event.plan?.playbookID,
            wasCompressed: event.plan?.wasCompressed ?? false,
            steps: (event.plan?.orderedSteps ?? []).map { step in
                EventExport.Step(
                    order: step.order,
                    firesAt: step.snoozedUntil ?? step.fireDate,
                    relative: step.relativeLabel,
                    audience: step.audience.displayName,
                    verb: step.actionVerb,
                    copy: step.effectiveCopy,
                    wasEditedByYou: step.userEditedCopy != nil,
                    timeIsPinned: step.userPinnedTime,
                    state: step.state.rawValue,
                    handedOffAt: step.handedOffAt
                )
            },
            material: event.scratchpad
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { item in
                    EventExport.Note(
                        kind: item.kind.rawValue,
                        text: item.text,
                        url: item.urlString,
                        hasPhoto: item.imageData != nil,
                        createdAt: item.createdAt
                    )
                },
            people: event.contacts.map(\.displayName)
        )
    }

    /// Deletes everything Forerun owns and leaves the app in a first-launch state without
    /// needing a relaunch. The user's calendar is not touched — Forerun never wrote to it except
    /// where they explicitly asked it to.
    @MainActor
    public static func deleteAll(in context: ModelContext, settings: AppSettings) {
        for event in (try? context.fetch(FetchDescriptor<TrackedEvent>())) ?? [] {
            context.delete(event)
        }
        StepOutcome.deleteAll(in: context)

        settings.trackedCalendarIDs = []
        settings.autoTrackColorFamilies = []
        settings.manuallyExcludedSourceIDs = []
        settings.manuallyIncludedSourceIDs = []
        settings.enabledKinds = EventKind.selectable.map(\.rawValue)
        settings.writeBackCalendarID = nil
        settings.tickTickRedProjectIDs = []
        settings.tickTickConnectedAt = nil
        settings.lastSyncAt = nil
        settings.hasCompletedOnboarding = false

        try? context.save()
    }
}

// MARK: - Plan as text

public enum PlanTextRenderer {
    /// Renders a ladder as plain text a co-leader can read in a message.
    ///
    /// No sync, no accounts, no invitations — the sharing story for v1 is that you paste it to
    /// someone. That respects the no-cloud constraint and is genuinely what most handoffs need.
    @MainActor
    public static func render(_ event: TrackedEvent, now: Date = .now) -> String {
        var lines: [String] = []

        lines.append(event.title)
        let when = event.isAllDay
            ? event.startDate.formatted(.dateTime.weekday(.wide).month(.wide).day())
            : event.startDate.formatted(date: .complete, time: .shortened)
        lines.append(when)
        lines.append("")

        let steps = event.plan?.orderedSteps ?? []
        guard !steps.isEmpty else {
            lines.append("No run-up planned yet.")
            return lines.joined(separator: "\n")
        }

        for step in steps {
            let date = (step.snoozedUntil ?? step.fireDate)
                .formatted(date: .abbreviated, time: .shortened)
            let marker: String
            switch step.state {
            case .done: marker = "[x]"
            case .skipped: marker = "[-]"
            default: marker = "[ ]"
            }
            let audience = step.audience == .me ? "" : " (\(step.audience.displayName))"
            lines.append("\(marker) \(date) — \(step.effectiveCopy)\(audience)")
        }

        if event.plan?.wasCompressed == true {
            lines.append("")
            lines.append("This is a tight run-up — the plan was squeezed into the time available.")
        }

        return lines.joined(separator: "\n")
    }
}
