import ForerunCore
import SwiftData
import SwiftUI

/// Today, Upcoming, Events — and Plan, which is reached from any of them but never owns a tab.
/// Settings lives behind a gear.
///
/// Upcoming sits in the middle because it answers the question between the other two: Today is
/// now, Events is what to watch, and Upcoming is what is building.
struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Destination = .today

    /// Not named `Tab` — SwiftUI owns that name in the iOS 18+ `TabView` API and shadowing it
    /// makes the builder unusable.
    enum Destination: Hashable {
        case today, upcoming, events
    }

    var body: some View {
        Group {
            if !app.settings.hasCompletedOnboarding {
                OnboardingView()
            } else {
                TabView(selection: $selection) {
                    Tab("Today", systemImage: "sun.horizon", value: Destination.today) {
                        TodayScreen()
                    }
                    Tab("Upcoming", systemImage: "rectangle.stack", value: Destination.upcoming) {
                        UpcomingScreen()
                    }
                    Tab("Events", systemImage: "calendar", value: Destination.events) {
                        EventsScreen()
                    }
                }
            }
        }
        .tint(Palette.amber)
        .onChange(of: app.deepLinkedEvent) { _, event in
            // The plan is pushed onto Today's stack, so the tab has to come with it — otherwise
            // tapping a notification while the Events tab is showing does nothing visible.
            guard event != nil else { return }
            selection = .today
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground is one of the four reschedule triggers. The others are the background
            // refresh task, a calendar change, and a settings change.
            guard phase == .active else { return }
            Task { await app.refresh() }
        }
    }
}

/// The store failed to open. This is the one error the app cannot recover from on its own, so
/// it gets a real sentence and a real next step rather than a crash.
struct StoreFailureView: View {
    let error: any Error

    var body: some View {
        VStack(spacing: 16) {
            Text("Forerun couldn't open its library.")
                .font(TypeRamp.eventTitle())
                .foregroundStyle(Palette.ink)
            Text("This is usually a failed update. Reinstalling the app will clear it — your "
                 + "calendar is untouched, and Forerun will rebuild its plans from it.")
                .font(TypeRamp.body())
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            Text(String(describing: error))
                .font(TypeRamp.diagnostic())
                .foregroundStyle(Palette.muted)
                .textSelection(.enabled)
                .padding(.top, 8)
        }
        .padding(Metrics.hMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperBackground()
    }
}
