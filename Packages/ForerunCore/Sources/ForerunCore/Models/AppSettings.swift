import Foundation
import SwiftData

/// Every default from the locked decisions, made visible and adjustable within its stated
/// limits — and no further. There is deliberately no escape hatch above the caps, no sound
/// picker, and no theme picker.
@Model
public final class AppSettings {
    /// Singleton marker. Fetching by a known constant is cheaper and safer than "first row."
    @Attribute(.unique) public var id: String

    public var quietHoursStart: Int
    public var quietHoursEnd: Int
    public var dailyNotificationBudget: Int
    public var maxStepsPerEvent: Int
    public var preferredDeliveryHour: Int

    public var trackedCalendarIDs: [String]
    public var autoTrackColorFamilies: [String]
    public var enabledKinds: [String]
    /// Events the user untracked by hand. An auto-track rule never re-tracks anything in here.
    public var manuallyExcludedSourceIDs: [String]
    /// Events the user tracked by hand that no rule would have caught. Kept so a rule change
    /// cannot silently untrack them.
    public var manuallyIncludedSourceIDs: [String]

    public var hasCompletedOnboarding: Bool
    public var lastSyncAt: Date?
    /// Calendar the buildWork write-back drops working blocks into. Nil means "ask me."
    public var writeBackCalendarID: String?

    // TickTick red rule. Inert unless the TickTick source is configured and connected.
    public var tickTickTreatsHighPriorityAsRed: Bool
    public var tickTickRedProjectIDs: [String]
    public var tickTickConnectedAt: Date?

    public static let singletonID = "app.persue.forerun.settings"

    /// Hard ceilings from locked decision 3. Not settings — limits on settings.
    public static let maxDailyBudget = 8
    public static let minDailyBudget = 3
    public static let maxStepsCeiling = 8
    public static let minStepsFloor = 3

    /// Deliberately **not** public. `@Attribute(.unique)` in SwiftData is upsert, not throw, so
    /// a stray `context.insert(AppSettings())` anywhere in the app would silently collapse onto
    /// the existing row and reset every setting to its default. `loadOrCreate` is the only way
    /// in from outside the package.
    init(
        id: String = AppSettings.singletonID,
        quietHoursStart: Int = 22,
        quietHoursEnd: Int = 7,
        dailyNotificationBudget: Int = 6,
        maxStepsPerEvent: Int = 5,
        preferredDeliveryHour: Int = 8,
        trackedCalendarIDs: [String] = [],
        autoTrackColorFamilies: [String] = [],
        enabledKinds: [String] = EventKind.selectable.map(\.rawValue),
        hasCompletedOnboarding: Bool = false
    ) {
        self.id = id
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.dailyNotificationBudget = dailyNotificationBudget
        self.maxStepsPerEvent = maxStepsPerEvent
        self.preferredDeliveryHour = preferredDeliveryHour
        self.trackedCalendarIDs = trackedCalendarIDs
        self.autoTrackColorFamilies = autoTrackColorFamilies
        self.enabledKinds = enabledKinds
        self.manuallyExcludedSourceIDs = []
        self.manuallyIncludedSourceIDs = []
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.lastSyncAt = nil
        self.writeBackCalendarID = nil
        self.tickTickTreatsHighPriorityAsRed = true
        self.tickTickRedProjectIDs = []
        self.tickTickConnectedAt = nil
    }
}

public extension AppSettings {
    var autoTrackFamilies: Set<ColorFamily> {
        get { Set(autoTrackColorFamilies.compactMap(ColorFamily.init(rawValue:))) }
        set { autoTrackColorFamilies = newValue.map(\.rawValue).sorted() }
    }

    var enabledEventKinds: Set<EventKind> {
        get { Set(enabledKinds.compactMap(EventKind.init(rawValue:))) }
        set { enabledKinds = newValue.map(\.rawValue).sorted() }
    }

    /// The pure snapshot the engine runs on. The engine never sees a SwiftData object.
    var engineSettings: EngineSettings {
        EngineSettings(
            quietHoursStart: quietHoursStart,
            quietHoursEnd: quietHoursEnd,
            dailyNotificationBudget: dailyNotificationBudget,
            maxStepsPerEvent: maxStepsPerEvent,
            preferredDeliveryHour: preferredDeliveryHour
        )
    }

    /// True when the delivery hour the user picked falls inside their own quiet hours. The
    /// engine resolves this on its own (it delivers at the end of quiet hours instead), but the
    /// settings screen should say so rather than letting it look like a bug.
    var deliveryHourCollidesWithQuietHours: Bool {
        guard quietHoursStart != quietHoursEnd else { return false }
        return quietHoursStart < quietHoursEnd
            ? (preferredDeliveryHour >= quietHoursStart && preferredDeliveryHour < quietHoursEnd)
            : (preferredDeliveryHour >= quietHoursStart || preferredDeliveryHour < quietHoursEnd)
    }

    /// Clamps every stepper to its locked limit. Called on every write, not just on the UI side,
    /// so a bad import or a stale export cannot raise the cap.
    ///
    /// Fields are clamped independently and their *relationship* is deliberately not enforced:
    /// `quietHoursStart == quietHoursEnd` legitimately means "quiet hours off," and a delivery
    /// hour inside quiet hours is resolved by the engine rather than rejected here. See
    /// `PrepPlanBuilder.deliveryHour(for:)`.
    func clampToLimits() {
        dailyNotificationBudget = min(max(dailyNotificationBudget, Self.minDailyBudget), Self.maxDailyBudget)
        maxStepsPerEvent = min(max(maxStepsPerEvent, Self.minStepsFloor), Self.maxStepsCeiling)
        preferredDeliveryHour = min(max(preferredDeliveryHour, 0), 23)
        quietHoursStart = min(max(quietHoursStart, 0), 23)
        quietHoursEnd = min(max(quietHoursEnd, 0), 23)
    }

    /// An unsaved settings object for the one case where the store could not be read at all.
    ///
    /// Deliberately never inserted. `@Attribute(.unique)` is upsert in SwiftData, so inserting
    /// this would collapse onto the real row and reset every setting to its default — which is
    /// exactly why the memberwise initialiser is not public.
    static func detachedDefaults() -> AppSettings {
        AppSettings()
    }

    /// Fetches the singleton, creating and inserting it on first launch.
    ///
    /// Saves immediately after inserting. Without the save, a second context on the same
    /// container cannot see the pending insert, creates its own, and the unique constraint
    /// upserts them into one row — silently discarding whichever context wrote first.
    @MainActor
    static func loadOrCreate(in context: ModelContext) throws -> AppSettings {
        let target = AppSettings.singletonID
        var descriptor = FetchDescriptor<AppSettings>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.clampToLimits()
            return existing
        }
        let created = AppSettings()
        context.insert(created)
        try context.save()
        return created
    }
}
