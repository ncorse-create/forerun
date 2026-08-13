import ForerunCore
import SwiftData
import SwiftUI

/// The morning glance. Restraint is still the feature.
///
/// One lifted hero — the single next thing you owe someone — then everything else due today as
/// follower cards, then three tiles that say how much is on you and what the cap is. No progress
/// bar, no "you've done X of Y", no count on anything. Marking everything done leaves a calm
/// screen, not a celebration.
struct TodayScreen: View {
    @Environment(AppEnvironment.self) private var app
    @State private var path = NavigationPath()
    @Query private var trackedEvents: [TrackedEvent]

    @State private var snoozeFailureMessage: String?
    @State private var handoff = HandoffController()
    @State private var handoffStep: PrepStep?

    /// How far back an unresolved step keeps appearing.
    ///
    /// A step you did not act on yesterday has not stopped mattering — but without a floor, every
    /// unresolved step from every event of the past month sat here permanently, and the only way
    /// to clear it was to swipe each one. That is a clearing ritual on the home screen, which is
    /// exactly what locked decision 5 forbids. Three days keeps "yesterday" while letting
    /// genuinely stale work fall away on its own.
    static let overdueGraceDays = 3

    /// Steps whose moment has arrived: due today, or overdue within the grace window.
    private var dueNow: [PrepStep] {
        let calendar = Calendar.current
        let endOfToday = calendar.startOfDay(for: .now).addingTimeInterval(86_400)
        let floor = calendar.date(byAdding: .day, value: -Self.overdueGraceDays, to: .now) ?? .distantPast

        return trackedEvents
            .filter { $0.disappearedAt == nil && !$0.isDuplicate }
            .compactMap(\.plan)
            .flatMap(\.steps)
            .filter { step in
                guard step.state.isSchedulable || step.state == .fired else { return false }
                let fireDate = step.snoozedUntil ?? step.fireDate
                guard fireDate < endOfToday, fireDate >= floor else { return false }
                // A pre-event step for something that has already happened is noise, not work.
                if let event = step.plan?.event, step.offsetSeconds < 0, event.startDate < .now {
                    return false
                }
                return true
            }
            .sorted { ($0.snoozedUntil ?? $0.fireDate) < ($1.snoozedUntil ?? $1.fireDate) }
    }

    private var hero: PrepStep? { dueNow.first }
    private var followers: [PrepStep] { Array(dueNow.dropFirst()) }

    /// `2 to your leads · 1 to you · 6 the daily cap`.
    ///
    /// The figure takes the colour of the audience it counts, so the first tile counts the
    /// **leadership** side specifically — amber is what leaders and volunteers are. When the day
    /// is aimed at participants or students instead, the first tile says so rather than filing
    /// them under a word that does not describe them.
    ///
    /// The third tile is how the daily cap becomes visible outside Settings. It is a promise the
    /// app makes and it was only ever written down in one place nobody looks at.
    private var tiles: [(figure: Int, label: String, tint: Color)] {
        let leadership = dueNow.filter(\.audience.isLeadership).count
        let audienceSide = dueNow.filter(\.audience.isAudienceSide).count
        let toSelf = dueNow.filter { $0.audience == .me }.count

        let first = audienceSide > leadership
            ? (audienceSide, "to your students", Palette.clay)
            : (leadership, "to your leads", Palette.amber)

        return [
            first,
            (toSelf, "to you", Palette.graphite),
            (app.settings.dailyNotificationBudget, "the daily cap", Palette.ink),
        ]
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleRow

                    if app.notificationsAreBlocked {
                        NotificationsOffBanner()
                            .padding(.top, 20)
                    }

                    if dueNow.isEmpty {
                        // A quiet day is the reward for staying ahead, not an empty list. No
                        // tiles either — a tile reading 0 turns an ordinary day into a scoreboard.
                        EmptyStateSentence(sentence: "Nothing needs you today.")
                            .padding(.top, 40)
                    } else {
                        stack
                    }
                }
                .padding(.horizontal, Metrics.hMargin)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fieldBackground()
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                UndoBanner()
                    .animation(.easeOut(duration: 0.2), value: app.pendingUndo)
            }
            .refreshable { await app.refresh() }
            .navigationDestination(for: TrackedEvent.self) { event in
                PlanScreen(event: event)
            }
            .onChange(of: app.deepLinkedEvent) { _, event in
                // A tapped notification lands on the plan the reminder came from, not on
                // whatever screen the app happened to be showing.
                guard let event else { return }
                path = NavigationPath()
                path.append(event)
                app.deepLinkedEvent = nil
            }
            .modifier(HandoffSheets(handoff: $handoff, step: $handoffStep))
            .alert(
                "No later left",
                isPresented: Binding(
                    get: { snoozeFailureMessage != nil },
                    set: { if !$0 { snoozeFailureMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { snoozeFailureMessage = nil }
            } message: {
                Text(snoozeFailureMessage ?? "")
            }
        }
    }

    /// Custom rather than `navigationTitle`, because the date sits beside it on the same baseline.
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Today")
                .font(TypeRamp.screenTitle())
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 12)
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(.caption))
                .foregroundStyle(Palette.muted)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var stack: some View {
        if let hero {
            HeroCard(
                step: hero,
                onOpen: { open(hero) },
                onMessage: messageAction(for: hero),
                onDone: { Task { await app.resolve(hero, as: .done) } }
            )
            .padding(.top, 20)
        }

        if !followers.isEmpty {
            EyebrowRow("Also today")
                .padding(.top, 22)
                .padding(.bottom, 8)

            VStack(spacing: 12) {
                ForEach(followers) { step in
                    Button { open(step) } label: { FollowerCard(step: step) }
                        .buttonStyle(.plain)
                        .contextMenu { stepActions(step) }
                        .accessibilityActions { stepActions(step) }
                }
            }
        }

        HStack(spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                FigureTile(figure: tile.figure, label: tile.label, tint: tile.tint)
            }
        }
        .padding(.top, 18)
    }

    /// Swipe is a `List` affordance and this screen is a `ScrollView` of containers, so the same
    /// three actions live in a context menu — and in `accessibilityActions`, so they are reachable
    /// without the gesture at all.
    @ViewBuilder private func stepActions(_ step: PrepStep) -> some View {
        Button("Done", systemImage: "checkmark") {
            Task { await app.resolve(step, as: .done) }
        }
        Button("Snooze", systemImage: "clock") {
            Task {
                if await !app.snooze(step) {
                    let title = step.plan?.event?.title ?? "That event"
                    snoozeFailureMessage = "This step can't move any later — \(title) is too close."
                }
            }
        }
        Button("Skip", systemImage: "xmark") {
            Task { await app.resolve(step, as: .skipped) }
        }
    }

    private func open(_ step: PrepStep) {
        guard let event = step.plan?.event else { return }
        path.append(event)
    }

    /// Nil for steps aimed at yourself — there is nobody to message.
    private func messageAction(for step: PrepStep) -> (() -> Void)? {
        guard step.audience.isContactable, let event = step.plan?.event else { return nil }
        return {
            handoffStep = step
            Task { await handoff.begin(step: step, event: event, app: app) }
        }
    }
}

// MARK: - Hero

/// The single next thing owed. One per screen, always the earliest unresolved step.
private struct HeroCard: View {
    let step: PrepStep
    let onOpen: () -> Void
    let onMessage: (() -> Void)?
    let onDone: () -> Void

    private var eventTitle: String { step.plan?.event?.title ?? "" }

    private var metaLine: String {
        guard let event = step.plan?.event else { return eventTitle.uppercased() }
        return "\(event.title) · \(RelativeDay.phrase(to: event.startDate))".uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        AudiencePill(audience: step.audience)
                        Spacer(minLength: 8)
                        Text((step.snoozedUntil ?? step.fireDate)
                            .formatted(date: .omitted, time: .shortened))
                            .font(.system(.caption))
                            .foregroundStyle(Palette.muted)
                    }

                    Text(step.effectiveCopy)
                        .font(.system(.title, design: .serif))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)

                    Text(metaLine)
                        .font(.system(.caption2, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            // Full-bleed inside the card: negative insets take it to the card's own edges.
            Rectangle()
                .fill(Palette.hairlineSoft)
                .frame(height: 1)
                .padding(.horizontal, -20)
                .padding(.top, 16)

            HStack(spacing: 9) {
                if let onMessage {
                    Button(action: onMessage) {
                        Text("Message \(step.audience.displayName.lowercased())")
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(Palette.paperLift)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 17)
                            .background(
                                Capsule().fill(Palette.amber)
                                    .shadow(color: Palette.amber.opacity(0.28), radius: 2.5, y: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onDone) {
                    Text("Done")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 17)
                        .background(Capsule().strokeBorder(Palette.dotSpent, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(.top, 15)
        }
        .padding(20)
        .container(surface: Palette.paperLift, radius: Metrics.rHero, elevation: .hero)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next: \(step.effectiveCopy). For \(eventTitle).")
    }
}

/// `● TO YOUR LEADS` — the dot carries the colour, the label stays ink.
///
/// Amber is ~3.1:1 on paper, so it is for fills and accents and never for a small label. The
/// colour is carried by the dot beside the word instead.
private struct AudiencePill: View {
    let audience: Audience

    private var label: String {
        audience == .me ? "To you" : "To your \(audience.displayName.lowercased())"
    }

    var body: some View {
        HStack(spacing: 6) {
            AudienceDot(audience: audience)
            Text(label.uppercased())
                .font(.system(.caption2, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Palette.ink)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(Capsule().fill(Palette.amber.opacity(0.13)))
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Followers

private struct FollowerCard: View {
    let step: PrepStep

    private var eventTitle: String { step.plan?.event?.title ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    AudienceDot(audience: step.audience)
                    Text(step.audience.displayName.uppercased())
                        .font(.system(.caption2, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(Palette.ink)
                }
                Spacer(minLength: 8)
                Text(step.relativeLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Palette.muted)
            }

            Text(step.effectiveCopy)
                .font(.system(.title3, design: .serif))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Text(eventTitle.uppercased())
                .font(.system(.caption2, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 15)
        .padding(.horizontal, 16)
        .container(elevation: .md)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.effectiveCopy). For \(eventTitle), \(step.audience.displayName).")
        .accessibilityHint("Double tap to open the plan")
    }
}

// MARK: - Tiles

private struct FigureTile: View {
    let figure: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(figure)")
                .font(.system(.title2, design: .serif))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(.caption2))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
        .padding(.horizontal, 12)
        .container(radius: Metrics.rTile, elevation: .sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(figure) \(label)")
    }
}

// MARK: - Shared

/// The message/mail composer plumbing, shared by Today and Plan.
struct HandoffSheets: ViewModifier {
    @Environment(AppEnvironment.self) private var app
    @Binding var handoff: HandoffController
    @Binding var step: PrepStep?

    func body(content: Content) -> some View {
        content
            .sheet(item: $handoff.sheet) { sheet in
                switch sheet {
                case .message(let recipients, let body):
                    MessageComposer(recipients: recipients, body: body) { result in
                        handoff.sheet = nil
                        if result == .sent, let step { Task { await app.messageWasSent(for: step) } }
                        step = nil
                    }
                    .ignoresSafeArea()
                case .mail(let recipients, let subject, let body):
                    MailComposer(recipients: recipients, subject: subject, body: body) { result in
                        handoff.sheet = nil
                        if result == .sent, let step { Task { await app.messageWasSent(for: step) } }
                        step = nil
                    }
                    .ignoresSafeArea()
                }
            }
            .alert(
                "Can't open a message",
                isPresented: Binding(
                    get: { handoff.message != nil },
                    set: { if !$0 { handoff.message = nil } }
                )
            ) {
                Button("OK", role: .cancel) { handoff.message = nil }
            } message: {
                Text(handoff.message ?? "")
            }
    }
}

/// Reminders cannot arrive. Said once, plainly, on the screen that would otherwise look normal.
private struct NotificationsOffBanner: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reminders are turned off")
                .font(TypeRamp.bodyEmphasis())
                .foregroundStyle(Palette.ink)
            Text("Forerun can still plan the run-up, but nothing will reach you until you turn "
                 + "notifications back on.")
                .font(TypeRamp.caption())
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(TypeRamp.micro())
            .foregroundStyle(Palette.amber)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .container(radius: Metrics.rTile, elevation: .sm)
        .accessibilityElement(children: .combine)
    }
}
