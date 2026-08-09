import ForerunCore
import SwiftData
import SwiftUI

/// Every default from the locked decisions, visible and adjustable within its stated limits —
/// and no further.
///
/// Deliberately absent: any way past 8 notifications a day, a sound picker, and a theme picker.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var exportedFile: ExportedFile?
    @State private var isConfirmingDelete = false
    @State private var deleteConfirmationText = ""
    @State private var isDisconnectingTickTick = false

    private var settings: AppSettings { app.settings }

    var body: some View {
        NavigationStack {
            Form {
                remindersSection
                quietHoursSection
                kindsSection
                sourcesSection
                if app.isTickTickAvailable { tickTickSection }
                diagnosticsSection
                dataSection
                aboutSection
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
            .sheet(item: $exportedFile) { file in
                ShareTextSheet(text: file.text, title: "Forerun export")
            }
            .alert("Delete everything?", isPresented: $isConfirmingDelete) {
                TextField("Type DELETE", text: $deleteConfirmationText)
                    .textInputAutocapitalization(.characters)
                Button("Delete", role: .destructive) {
                    guard deleteConfirmationText.uppercased() == "DELETE" else { return }
                    deleteConfirmationText = ""
                    Task {
                        await app.deleteAllData()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) { deleteConfirmationText = "" }
            } message: {
                Text("This removes every tracked event, every plan, every note and every "
                     + "reminder. Your calendar is untouched. Type DELETE to confirm.")
            }
        }
    }

    // MARK: Reminders

    private var remindersSection: some View {
        Section {
            Stepper(
                "At most \(settings.dailyNotificationBudget) a day",
                value: Binding(
                    get: { settings.dailyNotificationBudget },
                    set: { newValue in
                        settings.dailyNotificationBudget = newValue
                        Task { await app.settingsAffectingTimingChanged() }
                    }
                ),
                in: AppSettings.minDailyBudget...AppSettings.maxDailyBudget
            )

            Stepper(
                "At most \(settings.maxStepsPerEvent) per event",
                value: Binding(
                    get: { settings.maxStepsPerEvent },
                    set: { newValue in
                        settings.maxStepsPerEvent = newValue
                        Task { await app.settingsAffectingTimingChanged() }
                    }
                ),
                in: AppSettings.minStepsFloor...AppSettings.maxStepsCeiling
            )
        } header: {
            Text("Reminders")
        } footer: {
            Text("Eight a day is the ceiling, on purpose. Past that, reminders stop being "
                 + "reminders — you start swiping them away without reading them, and the ones "
                 + "that matter go with the rest.")
        }
    }

    private var quietHoursSection: some View {
        Section {
            hourPicker("Deliver at", value: \.preferredDeliveryHour)
            hourPicker("Quiet from", value: \.quietHoursStart)
            hourPicker("Quiet until", value: \.quietHoursEnd)
        } header: {
            Text("When")
        } footer: {
            if settings.quietHoursStart == settings.quietHoursEnd {
                Text("Quiet hours are off — reminders can arrive at any time.")
            } else if settings.deliveryHourCollidesWithQuietHours {
                Text("Your delivery hour is inside your quiet hours, so Forerun delivers at "
                     + "\(Self.hourLabel(settings.quietHoursEnd)) instead.")
            } else {
                Text("A reminder that would land inside quiet hours moves to "
                     + "\(Self.hourLabel(settings.preferredDeliveryHour)).")
            }
        }
    }

    private func hourPicker(
        _ title: String,
        value keyPath: ReferenceWritableKeyPath<AppSettings, Int>
    ) -> some View {
        Picker(title, selection: Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                Task { await app.settingsAffectingTimingChanged() }
            }
        )) {
            ForEach(0..<24, id: \.self) { hour in
                Text(Self.hourLabel(hour)).tag(hour)
            }
        }
    }

    private var kindsSection: some View {
        Section {
            ForEach(EventKind.selectable, id: \.self) { kind in
                Toggle(isOn: Binding(
                    get: { settings.enabledEventKinds.contains(kind) },
                    set: { isOn in
                        var kinds = settings.enabledEventKinds
                        if isOn { kinds.insert(kind) } else { kinds.remove(kind) }
                        settings.enabledEventKinds = kinds
                        Task { await app.settingsAffectingTimingChanged() }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.displayName)
                            .foregroundStyle(Palette.ink)
                        Text(PlaybookLibrary.playbook(for: kind).stepSummary)
                            .font(TypeRamp.caption())
                            .foregroundStyle(Palette.muted)
                    }
                }
                .tint(Palette.amber)
            }
        } header: {
            Text("Playbooks")
        } footer: {
            Text("Turning one off stops Forerun planning a run-up for that kind of event. "
                 + "Anything you already planned stays.")
        }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        Section("Sources") {
            NavigationLink {
                TrackingRulesScreen()
            } label: {
                LabeledContent("What to track", value: trackingSummary)
            }
            LabeledContent("Apple Calendar", value: calendarStatus)
        }
    }

    @ViewBuilder
    private var tickTickSection: some View {
        Section {
            if app.isTickTickConnected {
                LabeledContent("TickTick", value: "Connected")

                // TickTick has no per-task colour, so "red" has to be defined. Most people do
                // not know their red is a priority flag, which is why this is a sentence rather
                // than a bare toggle.
                Toggle(isOn: Binding(
                    get: { settings.tickTickTreatsHighPriorityAsRed },
                    set: { isOn in Task { await app.setTickTickHighPriorityIsRed(isOn) } }
                )) {
                    Text("High-priority tasks count as red")
                }
                .tint(Palette.amber)

                ForEach(app.tickTickProjects) { project in
                    Toggle(isOn: Binding(
                        get: { settings.tickTickRedProjectIDs.contains(project.id) },
                        set: { isOn in Task { await app.setTickTickProjectIsRed(project.id, isRed: isOn) } }
                    )) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Palette.forColorFamily(
                                    project.color.flatMap(ColorFamily.from(hex:)) ?? .gray
                                ))
                                .frame(width: 11, height: 11)
                            Text(project.name).foregroundStyle(Palette.ink)
                        }
                    }
                    .tint(Palette.amber)
                }

                Button("Disconnect TickTick", role: .destructive) {
                    isDisconnectingTickTick = true
                }
            } else {
                Button("Connect TickTick") {
                    Task { await app.connectTickTick() }
                }
                if let error = app.tickTickError {
                    Text(error)
                        .font(TypeRamp.caption())
                        .foregroundStyle(Palette.clay)
                }
            }
        } header: {
            Text("TickTick")
        } footer: {
            Text("TickTick's API returns tasks, not calendar events — subscribed calendars "
                 + "aren't reachable through it. If your TickTick work lives on a calendar, "
                 + "subscribing that calendar into Apple Calendar gets you more.")
        }
        .confirmationDialog(
            "Disconnect TickTick?",
            isPresented: $isDisconnectingTickTick,
            titleVisibility: .visible
        ) {
            Button("Disconnect and keep events", role: .destructive) {
                Task { await app.disconnectTickTick(removingTrackedEvents: false) }
            }
            Button("Disconnect and remove them", role: .destructive) {
                Task { await app.disconnectTickTick(removingTrackedEvents: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your TickTick sign-in is removed either way. Plans you edited are yours — "
                 + "you can keep them.")
        }
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                SkipRateScreen()
            } label: {
                Text("Which steps you skip")
            }
            NavigationLink {
                DiagnosticsScreen()
            } label: {
                Text("Diagnostics")
            }
        } footer: {
            Text("Private, and not a score. If you skip the same step every time, the timing is "
                 + "probably wrong — that's worth seeing.")
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section {
            Button("Export everything") {
                if let data = app.exportJSON(), let text = String(data: data, encoding: .utf8) {
                    exportedFile = ExportedFile(text: text)
                }
            }
            Button("Delete all data", role: .destructive) {
                isConfirmingDelete = true
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("Everything Forerun knows lives on this iPhone. There is no account and "
                 + "nothing is uploaded.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: app.appVersion)
            Button("Privacy policy") {
                if let url = URL(string: "https://persue.app/forerun/privacy") { openURL(url) }
            }
            Button("Support") {
                if let url = URL(string: "mailto:support@persue.app?subject=Forerun") { openURL(url) }
            }
        }
    }

    // MARK: Helpers

    struct ExportedFile: Identifiable {
        let id = UUID()
        let text: String
    }

    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var trackingSummary: String {
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
        case .noCalendarsResolved: "Unavailable"
        default: "Unavailable"
        }
    }
}

// MARK: - Skip rate

/// A diagnostic, not a score.
///
/// The question this answers is "is this rung of this ladder any good," never "how are you
/// doing." There is no streak, no completion percentage framed as an achievement, and no
/// comparison over time. If the −21d ask gets skipped nine times out of ten, the offset is
/// wrong and you should be able to see that.
struct SkipRateScreen: View {
    @Environment(AppEnvironment.self) private var app

    private var rows: [SkipRateRow] {
        app.skipRateRows().filter { $0.total >= SkipRateRow.minimumSampleSize }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                EmptyStateSentence(
                    sentence: "Not enough yet. Once you've dealt with the same step a few times, "
                        + "Forerun can tell you whether its timing is working."
                )
            } else {
                List {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stepDescription(row))
                                .font(TypeRamp.body())
                                .foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(sentence(for: row))
                                .font(TypeRamp.caption())
                                .foregroundStyle(row.isNoteworthy ? Palette.clay : Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                        .accessibilityElement(children: .combine)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper)
        .navigationTitle("Which steps you skip")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stepDescription(_ row: SkipRateRow) -> String {
        guard !row.playbookStepID.hasPrefix("custom.") else { return "A step you added" }
        let playbook = PlaybookLibrary.playbook(for: row.kind)
        let step = playbook.steps.first { $0.id == row.playbookStepID }
        return step?.template.replacingOccurrences(of: "{title}", with: "an event")
            ?? row.playbookStepID
    }

    /// Phrased as a fact about the step, never as a judgement about the person.
    private func sentence(for row: SkipRateRow) -> String {
        if row.isNoteworthy {
            return "Skipped \(row.skippedCount) of \(row.total) times. That usually means the "
                + "timing is wrong, not that the step is."
        }
        return "Skipped \(row.skippedCount) of \(row.total) times."
    }
}

// MARK: - Diagnostics

/// Answers the runtime questions Spike B could not answer from a command line: whether
/// subscribed calendars appear, whether every calendar has a usable colour, and whether
/// recurring occurrences really do share one identifier.
struct DiagnosticsScreen: View {
    @Environment(AppEnvironment.self) private var app
    @State private var recurringNote = "—"

    var body: some View {
        List {
            Section("Calendar") {
                LabeledContent("Access", value: accessLabel)
                LabeledContent("Calendars", value: "\(app.availableCalendars.count)")
                LabeledContent("Subscribed", value: "\(app.availableCalendars.filter(\.isSubscribed).count)")
                LabeledContent("Writable", value: "\(app.availableCalendars.filter(\.isWritable).count)")
                LabeledContent("Events in window", value: "\(app.sync.browsableEvents.count)")
                LabeledContent("Recurring", value: recurringNote)
            }

            Section("Colours") {
                ForEach(app.availableCalendars) { calendar in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Palette.forColorFamily(calendar.colorFamily))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(calendar.title)
                                .font(TypeRamp.caption())
                                .foregroundStyle(Palette.ink)
                            Text(calendar.isSubscribed ? "subscribed" : "local")
                                .font(TypeRamp.micro())
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Text(calendar.colorHex ?? "no colour")
                            .font(TypeRamp.diagnostic())
                            .foregroundStyle(Palette.muted)
                    }
                }
            }

            Section("Notifications") {
                LabeledContent("Pending", value: "\(app.scheduler.pendingCount)")
                if app.scheduler.truncatedStepCount > 0 {
                    LabeledContent("Beyond the limit", value: "\(app.scheduler.truncatedStepCount)")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.paper)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let recurring = app.sync.browsableEvents.filter(\.hasRecurrenceRules)
            let series = Set(recurring.map { EventKitSource.seriesIdentifier(from: $0.sourceID) })
            recurringNote = recurring.isEmpty
                ? "none"
                : "\(recurring.count) occurrences, \(series.count) series"
        }
    }

    private var accessLabel: String {
        guard let error = app.calendarAccessError else { return "Full" }
        return AppEnvironment.message(for: error)
    }
}
