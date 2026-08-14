import ForerunCore
import SwiftUI

/// What iOS will actually deliver, and when.
///
/// Every other surface in the app shows what Forerun *intends*. This one reads the pending
/// requests back out of `UNUserNotificationCenter` and shows what the system has actually
/// accepted — the only evidence that matters for an app whose entire job is to reach you.
struct ScheduledRemindersScreen: View {
    @Environment(AppEnvironment.self) private var app

    @State private var pending: [NotificationScheduler.PendingReminder] = []
    @State private var isLoading = true
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case sent
        case failed
    }

    var body: some View {
        List {
            statusSection
            testSection
            queueSection
        }
        .scrollContentBackground(.hidden)
        .background(Palette.paper)
        .navigationTitle("Scheduled reminders")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            LabeledContent("Permission", value: app.notificationStatusLabel)
            LabeledContent("Queued with iOS", value: "\(pending.filter { !$0.isTest }.count)")
            if app.scheduler.truncatedStepCount > 0 {
                LabeledContent("Beyond the limit",
                               value: "\(app.scheduler.truncatedStepCount)")
            }
        } header: {
            Text("Status")
        } footer: {
            if app.notificationsAreBlocked {
                Text("Notifications are turned off for Forerun, so nothing below can reach you. "
                     + "Everything is still scheduled and will start arriving the moment you turn "
                     + "them back on.")
            } else if app.scheduler.truncatedStepCount > 0 {
                Text("iOS holds a limited number of pending reminders per app, so Forerun "
                     + "schedules the soonest ones and adds the rest as these are delivered. "
                     + "Nothing is lost.")
            } else {
                Text("Read back from iOS itself, not from Forerun's own records — this is what "
                     + "your iPhone will actually deliver.")
            }
        }
    }

    // MARK: Test

    private var testSection: some View {
        Section {
            Button {
                Task {
                    let sent = await app.scheduler.sendTestReminder(in: 15)
                    testState = sent ? .sent : .failed
                    await reload()
                }
            } label: {
                Label("Send a test reminder", systemImage: "bell.badge")
            }
            .disabled(testState == .sent)
        } footer: {
            switch testState {
            case .idle:
                Text("Sends one real reminder in fifteen seconds, down the same path every other "
                     + "reminder takes. Lock your iPhone and wait for it.")
            case .sent:
                Text("On its way. Lock your iPhone — it should arrive within fifteen seconds. If "
                     + "it doesn't, notifications aren't reaching you and nothing else here will "
                     + "either.")
            case .failed:
                Text("Forerun couldn't schedule it, which means notifications are not permitted. "
                     + "Turn them on in iOS Settings and try again.")
            }
        }
    }

    // MARK: Queue

    @ViewBuilder private var queueSection: some View {
        Section("Next up") {
            if isLoading {
                Text("Reading the queue…")
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.muted)
            } else if pending.isEmpty {
                Text(app.notificationsAreBlocked
                     ? "Nothing is queued, because notifications are off."
                     : "Nothing is queued. Track an event and its run-up lands here.")
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(pending) { reminder in
                    ReminderRow(reminder: reminder)
                }
            }
        }
    }

    private func reload() async {
        pending = await app.scheduler.pendingReminders()
        isLoading = false
    }
}

private struct ReminderRow: View {
    let reminder: NotificationScheduler.PendingReminder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(reminder.isTest ? "Test reminder" : reminder.title)
                    .font(TypeRamp.bodyEmphasis())
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(whenLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
            }

            Text(reminder.body)
                .font(TypeRamp.caption())
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(reminder.title), \(whenLabel). \(reminder.body)")
    }

    /// The real fire date, straight from the trigger. "Unknown" would mean iOS holds a request
    /// with no next date — which is a request that will never arrive, and worth showing plainly.
    private var whenLabel: String {
        guard let date = reminder.fireDate else { return "never" }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
            .hour().minute())
    }
}
