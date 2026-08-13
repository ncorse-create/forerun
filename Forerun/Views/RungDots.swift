import ForerunCore
import SwiftUI

/// What is left of an event's ladder.
///
/// One dot per rung. A spent rung goes grey; the rungs still ahead keep their audience colour, in
/// playbook order. It **empties** as you work — it is a countdown of what remains, never a bar
/// that fills up toward a finished state. Locked decision 4 rules out completion percentages, and
/// a gauge that fills is the same idea wearing dots.
struct RungDots: View {
    let plan: PrepPlan?
    let cap: Int

    private var rungs: [PrepStep] {
        // Playbook order, capped — a plan with a custom step added still draws a steady row.
        Array((plan?.orderedSteps ?? []).prefix(cap))
    }

    private var remaining: Int {
        rungs.filter { !$0.state.isResolved }.count
    }

    /// Empty plans draw nothing rather than a row of grey placeholders, which would read as
    /// "nothing to do here" on an event whose ladder simply has not been built yet.
    private var isDrawable: Bool { !rungs.isEmpty }

    var body: some View {
        if isDrawable {
            HStack(spacing: 5) {
                ForEach(rungs) { step in
                    Circle()
                        .fill(step.state.isResolved
                              ? Palette.dotSpent
                              : Palette.forAudience(step.audience))
                        .frame(width: 8, height: 8)
                }
                Spacer(minLength: 8)
                Text("\(remaining) of \(rungs.count) left")
                    .font(.system(.caption2))
                    .foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(remaining) of \(rungs.count) steps left")
        }
    }
}

/// The rung row on its tinted band, as it appears in the footer of an event card.
struct RungFooter: View {
    let plan: PrepPlan?
    let cap: Int

    var body: some View {
        RungDots(plan: plan, cap: cap)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.footerTint)
    }
}

/// `EVENT NAME · IN 3 DAYS` — the meta line under a sentence.
enum RelativeDay {
    static func phrase(to date: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case ..<0: return "has passed"
        case 0: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }
}
