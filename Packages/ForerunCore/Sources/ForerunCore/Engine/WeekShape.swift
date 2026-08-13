import Foundation

/// The shape of a stretch of days: how much each one carries, and who it is for.
///
/// Pure value types with no SwiftData, so the Upcoming screen's arithmetic is testable without a
/// simulator — the same reason the rest of the engine lives here.
public struct DayLoad: Sendable, Hashable, Identifiable {
    /// Start of day.
    public let day: Date
    /// One entry per scheduled reminder that day, in fire order. Audience, not count, because the
    /// load bars are coloured by who each ask is for.
    public let audiences: [Audience]
    /// Reminders that were placed on this day but whose playbook offset pointed at another one.
    public let arrivals: Int

    public var count: Int { audiences.count }
    public var id: Date { day }

    public init(day: Date, audiences: [Audience], arrivals: Int = 0) {
        self.day = day
        self.audiences = audiences
        self.arrivals = arrivals
    }

    public func isAtCap(_ budget: Int) -> Bool { count >= budget }
}

/// One scheduled reminder, reduced to what the week view needs.
public struct ScheduledAsk: Sendable, Hashable {
    public let fireDate: Date
    /// Where the playbook offset alone would have put it: `eventStart + offsetSeconds`.
    public let idealDate: Date
    public let audience: Audience
    /// A step the user pinned or snoozed moved because *they* moved it, and must never be
    /// attributed to the daily budget.
    public let wasMovedByUser: Bool

    public init(fireDate: Date, idealDate: Date, audience: Audience, wasMovedByUser: Bool) {
        self.fireDate = fireDate
        self.idealDate = idealDate
        self.audience = audience
        self.wasMovedByUser = wasMovedByUser
    }

    /// True when the engine put this ask on a different **day** from the one its offset asked for.
    ///
    /// Compared at day granularity on purpose: quiet hours and the preferred delivery hour shift
    /// the *time* of almost every ask without displacing it, and counting those as moves would
    /// make the cap sentence claim the budget did something it didn't.
    public func wasDisplaced(_ calendar: Calendar) -> Bool {
        guard !wasMovedByUser else { return false }
        return calendar.startOfDay(for: fireDate) != calendar.startOfDay(for: idealDate)
    }
}

public enum WeekShape {

    /// Buckets asks into one `DayLoad` per day across `days`, including days with nothing so the
    /// strip keeps seven equal columns.
    public static func days(
        from start: Date,
        count days: Int,
        asks: [ScheduledAsk],
        calendar: Calendar = .current
    ) -> [DayLoad] {
        let first = calendar.startOfDay(for: start)
        let byDay = Dictionary(grouping: asks) { calendar.startOfDay(for: $0.fireDate) }

        return (0..<max(0, days)).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            let sameDay = (byDay[day] ?? []).sorted { $0.fireDate < $1.fireDate }
            return DayLoad(
                day: day,
                audiences: sameDay.map(\.audience),
                arrivals: sameDay.filter { $0.wasDisplaced(calendar) }.count
            )
        }
    }
}

/// Puts the daily cap into a sentence.
///
/// The cap is a promise the app makes, and until now it was only ever visible in Settings. This
/// states it in plain language from what the engine actually did — never from an estimate.
public enum CapNarrator {

    /// Nil when there is nothing worth saying, which is most weeks.
    public static func sentence(
        for days: [DayLoad],
        budget: Int,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        let loaded = days.filter { $0.count > 0 }
        guard let heaviest = loaded.max(by: { $0.count < $1.count }) else { return nil }

        var formatter = Date.FormatStyle.dateTime.weekday(.wide)
        formatter.locale = locale
        let dayName = heaviest.day.formatted(formatter)

        guard heaviest.isAtCap(budget) else {
            // Not at the cap: say only which day is heaviest, and only when that is a real
            // statement rather than "one day has one thing on it".
            guard heaviest.count > 1 else { return nil }
            return "\(dayName) is the heaviest day this week, with \(spell(heaviest.count))."
        }

        let capPhrase = "\(dayName) sits at the cap of \(spell(budget))"

        // Which days gave up asks so this one could stay at the cap. Only named when every
        // displaced ask landed on the same day — otherwise the sentence would be inventing a
        // tidiness the schedule does not have.
        let movedTotal = days.reduce(0) { $0 + $1.arrivals }
        guard movedTotal > 0 else { return capPhrase + "." }

        let receivers = days.filter { $0.arrivals > 0 }
        let asks = movedTotal == 1 ? "one ask" : "\(spell(movedTotal)) asks"

        if receivers.count == 1, let only = receivers.first,
           calendar.startOfDay(for: only.day) != calendar.startOfDay(for: heaviest.day) {
            return "\(capPhrase) — \(asks) moved to \(only.day.formatted(formatter)) to keep it there."
        }
        return "\(capPhrase) — \(asks) moved to keep it there."
    }

    /// Small numbers read as words in a sentence. Above ten the digit is clearer, and the cap
    /// itself can never exceed eight.
    private static func spell(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five",
                     "six", "seven", "eight", "nine", "ten"]
        return words.indices.contains(n) ? words[n] : String(n)
    }
}
