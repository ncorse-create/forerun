import ForerunCore
import SwiftUI

/// Three screens, no account, no email capture. Connect a calendar, pick what to track, done.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                WelcomePage(onContinue: { withAnimation { page = 1 } })
                    .tag(0)
                ConnectPage(onContinue: { withAnimation { page = 2 } })
                    .tag(1)
                ChooseWhatToTrackPage(onFinish: { app.completeOnboarding() })
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        }
        .paperBackground()
    }
}

private struct OnboardingScaffold<Content: View>: View {
    let title: String
    let body1: String
    let body2: String?
    let actionTitle: String
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scrollable, because at accessibility Dynamic Type sizes this content is taller
            // than the screen. Without it the spacers collapsed and the action button went off
            // the bottom, which made onboarding literally unfinishable.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer(minLength: 32)
                    Text(title)
                        .font(TypeRamp.screenTitle())
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(body1)
                        .font(TypeRamp.body())
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let body2 {
                        Text(body2)
                            .font(TypeRamp.body())
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.hMargin)
                .padding(.bottom, 24)
            }

            // Pinned below the scroll view, so it is reachable at every type size.
            Button(actionTitle, action: action)
                .font(TypeRamp.bodyEmphasis())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Palette.amber, in: .rect(cornerRadius: 12))
                .foregroundStyle(Palette.paper)
                .padding(.horizontal, Metrics.hMargin)
                .padding(.bottom, 44)
        }
    }
}

private struct WelcomePage: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: "Your calendar knows when.\nForerun works out what comes before.",
            body1: "Pick the events that need a run-up. Forerun builds the ladder — who to ask, "
                 + "when to chase, what to send — and tells you at the right moment.",
            body2: "A handful of reminders. Never a to-do list.",
            actionTitle: "Start",
            action: onContinue
        ) {
            EmptyView()
        }
    }
}

private struct ConnectPage: View {
    @Environment(AppEnvironment.self) private var app
    let onContinue: () -> Void

    private var isConnected: Bool { app.calendarAccessError == nil && !app.availableCalendars.isEmpty }

    var body: some View {
        OnboardingScaffold(
            title: "Connect a calendar",
            body1: "Forerun reads the events on the calendars you choose. It stays on this "
                 + "iPhone — nothing is uploaded, and there is no account.",
            body2: nil,
            actionTitle: isConnected ? "Next" : "Connect Apple Calendar",
            action: {
                if isConnected {
                    onContinue()
                } else {
                    Task {
                        let granted = await app.connectAppleCalendar()
                        if granted { onContinue() }
                    }
                }
            }
        ) {
            if app.calendarAccessError == .denied || app.calendarAccessError == .writeOnlyAccess {
                Text("Calendar access is off. You can turn it on in Settings → Privacy → "
                     + "Calendars, then come back.")
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.clay)
            } else if isConnected {
                Text("Connected. \(app.availableCalendars.count) calendars found.")
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.muted)
            }
        }
    }
}

private struct ChooseWhatToTrackPage: View {
    @Environment(AppEnvironment.self) private var app
    let onFinish: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: "What should Forerun watch?",
            body1: "Pick a calendar, or a colour if you colour-code. You can also tap any single "
                 + "event later — this is just a starting point.",
            body2: nil,
            actionTitle: "Done",
            action: onFinish
        ) {
            VStack(alignment: .leading, spacing: 4) {
                    ForEach(app.availableCalendars) { calendar in
                        Toggle(isOn: Binding(
                            get: { app.settings.trackedCalendarIDs.contains(calendar.id) },
                            set: { newValue in
                                Task { await app.setCalendarTracked(calendar.id, tracked: newValue) }
                            }
                        )) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Palette.forColorFamily(calendar.colorFamily))
                                    .frame(width: 11, height: 11)
                                Text(calendar.title)
                                    .font(TypeRamp.body())
                                    .foregroundStyle(Palette.ink)
                            }
                        }
                        .tint(Palette.amber)
                    }
            }
        }
    }
}
