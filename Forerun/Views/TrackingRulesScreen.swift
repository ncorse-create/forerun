import ForerunCore
import SwiftData
import SwiftUI

/// What Forerun tracks on its own.
///
/// Two rules, OR'd: by calendar and by colour. A manually untracked event is never re-tracked
/// by either, which is stated in the footer rather than left to be discovered.
struct TrackingRulesScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var settings: AppSettings { app.settings }

    var body: some View {
        NavigationStack {
            Form {
                if app.availableCalendars.isEmpty {
                    Section {
                        Text("Connect a calendar to choose what Forerun watches.")
                            .font(TypeRamp.body())
                            .foregroundStyle(Palette.muted)
                        Button("Connect Apple Calendar") {
                            Task { await app.connectAppleCalendar() }
                        }
                    }
                } else {
                    calendarSection
                    colorSection
                }

                if !settings.manuallyExcludedSourceIDs.isEmpty {
                    Section {
                        Button("Clear \(settings.manuallyExcludedSourceIDs.count) untracked event\(settings.manuallyExcludedSourceIDs.count == 1 ? "" : "s")") {
                            settings.manuallyExcludedSourceIDs.removeAll()
                            Task { await app.refresh() }
                        }
                    } footer: {
                        Text("Events you untracked by hand stay untracked, even if a rule would "
                             + "otherwise pick them up. Clearing the list lets the rules apply again.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .navigationTitle("What to track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var calendarSection: some View {
        Section {
            ForEach(app.availableCalendars) { calendar in
                Toggle(isOn: Binding(
                    get: { settings.trackedCalendarIDs.contains(calendar.id) },
                    set: { newValue in
                        Task { await app.setCalendarTracked(calendar.id, tracked: newValue) }
                    }
                )) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Palette.forColorFamily(calendar.colorFamily))
                            .frame(width: 11, height: 11)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(calendar.title)
                                .foregroundStyle(Palette.ink)
                            if calendar.isSubscribed || !calendar.sourceTitle.isEmpty {
                                Text(calendar.isSubscribed
                                     ? "Subscribed · \(calendar.sourceTitle)"
                                     : calendar.sourceTitle)
                                    .font(TypeRamp.caption())
                                    .foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }
                .tint(Palette.amber)
            }
        } header: {
            Text("Calendars")
        } footer: {
            Text("Everything on a chosen calendar gets a plan.")
        }
    }

    private var colorSection: some View {
        Section {
            ForEach(ColorFamily.allCases, id: \.self) { family in
                Toggle(isOn: Binding(
                    get: { settings.autoTrackFamilies.contains(family) },
                    set: { newValue in
                        Task { await app.setColorFamilyTracked(family, tracked: newValue) }
                    }
                )) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Palette.forColorFamily(family))
                            .frame(width: 11, height: 11)
                        Text(family.displayName)
                            .foregroundStyle(Palette.ink)
                    }
                }
                .tint(Palette.amber)
            }
        } header: {
            Text("Colours")
        } footer: {
            Text("If you colour-code your calendar, this is usually the faster rule. "
                 + "Colours and calendars stack — an event matching either one is tracked.")
        }
    }
}
