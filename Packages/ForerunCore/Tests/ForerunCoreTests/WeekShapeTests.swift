import Foundation
import Testing
@testable import ForerunCore

@Suite("The week's shape")
struct WeekShapeTests {

    private let calendar = Calendar(identifier: .gregorian)
    private var monday: Date {
        DateComponents(calendar: calendar, year: 2026, month: 8, day: 10, hour: 9).date!
    }

    private func ask(
        day: Int,
        hour: Int = 9,
        idealDay: Int? = nil,
        audience: Audience = .leaders,
        userMoved: Bool = false
    ) -> ScheduledAsk {
        let fire = DateComponents(
            calendar: calendar, year: 2026, month: 8, day: day, hour: hour
        ).date!
        let ideal = DateComponents(
            calendar: calendar, year: 2026, month: 8, day: idealDay ?? day, hour: hour
        ).date!
        return ScheduledAsk(fireDate: fire, idealDate: ideal, audience: audience,
                            wasMovedByUser: userMoved)
    }

    @Test("A week always has seven columns, including the days with nothing on them")
    func sevenColumns() {
        let days = WeekShape.days(from: monday, count: 7, asks: [ask(day: 12)], calendar: calendar)
        #expect(days.count == 7)
        #expect(days.filter { $0.count == 0 }.count == 6)
    }

    @Test("Asks land on the day they fire, in fire order")
    func bucketsByDay() {
        let asks = [
            ask(day: 12, hour: 17, audience: .students),
            ask(day: 12, hour: 8, audience: .leaders),
        ]
        let days = WeekShape.days(from: monday, count: 7, asks: asks, calendar: calendar)
        let wednesday = days.first { calendar.component(.day, from: $0.day) == 12 }
        #expect(wednesday?.audiences == [.leaders, .students])
    }

    @Test("A different time on the same day is not a displacement")
    func quietHoursIsNotAMove() {
        // Quiet hours and the preferred delivery hour move almost every ask's *time*. Counting
        // those as moves would have the cap sentence claim the budget did something it didn't.
        let shifted = ScheduledAsk(
            fireDate: DateComponents(calendar: calendar, year: 2026, month: 8, day: 12, hour: 9).date!,
            idealDate: DateComponents(calendar: calendar, year: 2026, month: 8, day: 12, hour: 2).date!,
            audience: .leaders,
            wasMovedByUser: false
        )
        #expect(shifted.wasDisplaced(calendar) == false)
    }

    @Test("A different day is a displacement")
    func differentDayIsAMove() {
        #expect(ask(day: 14, idealDay: 15).wasDisplaced(calendar))
    }

    @Test("A step the user moved is never counted against the budget")
    func userMovesAreNotBudgetMoves() {
        #expect(ask(day: 14, idealDay: 15, userMoved: true).wasDisplaced(calendar) == false)
    }

    @Test("A quiet week says nothing at all")
    func quietWeekIsSilent() {
        let days = WeekShape.days(from: monday, count: 7, asks: [], calendar: calendar)
        #expect(CapNarrator.sentence(for: days, budget: 6, calendar: calendar) == nil)
    }

    @Test("One thing on one day is not worth a sentence")
    func singleAskIsSilent() {
        let days = WeekShape.days(from: monday, count: 7, asks: [ask(day: 12)], calendar: calendar)
        #expect(CapNarrator.sentence(for: days, budget: 6, calendar: calendar) == nil)
    }

    @Test("Below the cap, the sentence names the heaviest day and nothing more")
    func heaviestDay() {
        let asks = (0..<3).map { ask(day: 14, hour: 8 + $0) }
        let days = WeekShape.days(from: monday, count: 7, asks: asks, calendar: calendar)
        let sentence = CapNarrator.sentence(for: days, budget: 6, calendar: calendar)
        #expect(sentence == "Friday is the heaviest day this week, with three.")
    }

    @Test("At the cap with nothing displaced, the sentence states the cap and stops")
    func atCapNothingMoved() {
        let asks = (0..<6).map { ask(day: 15, hour: 8 + $0) }
        let days = WeekShape.days(from: monday, count: 7, asks: asks, calendar: calendar)
        let sentence = CapNarrator.sentence(for: days, budget: 6, calendar: calendar)
        #expect(sentence == "Saturday sits at the cap of six.")
    }

    @Test("At the cap with everything displaced to one day, that day is named")
    func atCapNamesTheReceiver() {
        // Six on Saturday, and two that wanted Saturday landed on Friday instead.
        var asks = (0..<6).map { ask(day: 15, hour: 8 + $0) }
        asks.append(ask(day: 14, hour: 9, idealDay: 15))
        asks.append(ask(day: 14, hour: 10, idealDay: 15))
        let days = WeekShape.days(from: monday, count: 7, asks: asks, calendar: calendar)
        let sentence = CapNarrator.sentence(for: days, budget: 6, calendar: calendar)
        #expect(sentence == "Saturday sits at the cap of six — two asks moved to Friday to keep it there.")
    }

    @Test("Displacements scattered across days name no destination")
    func scatteredMovesNameNoDay() {
        // Naming one would invent a tidiness the schedule does not have.
        var asks = (0..<6).map { ask(day: 15, hour: 8 + $0) }
        asks.append(ask(day: 14, hour: 9, idealDay: 15))
        asks.append(ask(day: 13, hour: 9, idealDay: 15))
        let days = WeekShape.days(from: monday, count: 7, asks: asks, calendar: calendar)
        let sentence = CapNarrator.sentence(for: days, budget: 6, calendar: calendar)
        #expect(sentence == "Saturday sits at the cap of six — two asks moved to keep it there.")
    }

    @Test("A day is at the cap when it reaches the budget, not when it passes it")
    func capIsInclusive() {
        let day = DayLoad(day: monday, audiences: Array(repeating: Audience.leaders, count: 6))
        #expect(day.isAtCap(6))
        #expect(DayLoad(day: monday, audiences: [.leaders]).isAtCap(6) == false)
    }
}
