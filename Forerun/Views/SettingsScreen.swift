import ForerunCore
import SwiftData
import SwiftUI

/// Everything from the locked decisions, made visible and adjustable within its stated limits.
/// Filled out in Sprint 11; the sources section lands in Sprint 3 because the tracking rules
/// need somewhere to live.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Sources") {
                    NavigationLink {
                        TrackingRulesScreen()
                    } label: {
                        LabeledContent("What to track", value: trackingSummary)
                    }
                    LabeledContent("Apple Calendar", value: calendarStatus)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var trackingSummary: String {
        guard let settings = app.settings else { return "None" }
        let calendars = settings.trackedCalendarIDs.count
        let colors = settings.autoTrackFamilies.count
        switch (calendars, colors) {
        case (0, 0): return "Nothing yet"
        case (let c, 0): return "\(c) calendar\(c == 1 ? "" : "s")"
        case (0, let f): return "\(f) colour\(f == 1 ? "" : "s")"
        case (let c, let f): return "\(c) calendar\(c == 1 ? "" : "s"), \(f) colour\(f == 1 ? "" : "s")"
        }
    }

    private var calendarStatus: String {
        switch app.calendarAccessError {
        case nil: "Connected"
        case .denied: "Access off"
        case .restricted: "Restricted"
        case .writeOnlyAccess: "Write-only"
        case .notDetermined: "Not connected"
        default: "Unavailable"
        }
    }
}
