import ForerunCore
import SwiftData
import SwiftUI

/// See the ladder. Change the ladder.
///
/// A vertical timeline with a hairline rail, not a list of boxes. Each step is a dot on the rail
/// coloured by who it is for, with the date and a relative label above the sentence.
struct PlanScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Bindable var event: TrackedEvent

    @State private var editingStep: PrepStep?
    @State private var isAddingStep = false
    @State private var regenerationPreview: PlanMergeResult?
    @State private var isCorrectingKind = false
    @State private var snoozeFailureMessage: String?
    @State private var handoff = HandoffController()
    @State private var workBlockMessage: String?
    @State private var isSharing = false

    private var steps: [PrepStep] {
        event.plan?.orderedSteps ?? []
    }

    /// A `List` rather than a `ScrollView`, because `swipeActions` is a `List`-only modifier —
    /// swipe-to-done and swipe-to-skip would silently not exist anywhere else. Every row clears
    /// its insets, separator and background so the timeline still reads as a hairline rail
    /// rather than a grouped table.
    var body: some View {
        List {
            Group {
                header

                if event.needsKindConfirmation {
                    KindConfirmationChip(event: event) { isCorrectingKind = true }
                        .padding(.horizontal, Metrics.hMargin)
                        .padding(.bottom, 20)
                }

                if event.plan?.wasCompressed == true {
                    CompressionBanner(droppedCount: event.plan?.droppedToCompressionCount ?? 0)
                        .padding(.horizontal, Metrics.hMargin)
                        .padding(.bottom, 24)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if steps.isEmpty {
                EmptyStateSentence(sentence: emptySentence)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                timeline
            }

            Group {
                Hairline().padding(.top, 20)
                ScratchpadSection(event: event)
                Hairline()
                EventPeopleSection(event: event)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Palette.paper.ignoresSafeArea())
        .tint(Palette.amber)
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add a step", systemImage: "plus") { isAddingStep = true }
                    Button("Change what this is", systemImage: "tag") { isCorrectingKind = true }
                    Button("Share as text", systemImage: "square.and.arrow.up") { isSharing = true }
                    Divider()
                    Button("Rebuild plan", systemImage: "arrow.clockwise") {
                        regenerationPreview = app.planning.regenerationPreview(for: event)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editingStep) { step in
            StepEditorSheet(step: step, event: event)
        }
        .sheet(isPresented: $isAddingStep) {
            CustomStepSheet(event: event)
        }
        .sheet(isPresented: $isCorrectingKind) {
            KindPickerSheet(event: event)
        }
        .sheet(isPresented: $isSharing) {
            // Plain text, shared however the user likes. No sync infrastructure, no account for
            // the person receiving it — they just read it.
            ShareTextSheet(text: app.planAsText(for: event), title: event.title)
        }
        .sheet(item: $handoff.sheet) { sheet in
            switch sheet {
            case .message(let recipients, let body):
                MessageComposer(recipients: recipients, body: body) { result in
                    handoff.sheet = nil
                    if result == .sent, let step = handoffStep {
                        Task { await app.messageWasSent(for: step) }
                    }
                    handoffStep = nil
                }
                .ignoresSafeArea()
            case .mail(let recipients, let subject, let body):
                MailComposer(recipients: recipients, subject: subject, body: body) { result in
                    handoff.sheet = nil
                    if result == .sent, let step = handoffStep {
                        Task { await app.messageWasSent(for: step) }
                    }
                    handoffStep = nil
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
        .alert(
            "Couldn't block the time",
            isPresented: Binding(
                get: { workBlockMessage != nil },
                set: { if !$0 { workBlockMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { workBlockMessage = nil }
        } message: {
            Text(workBlockMessage ?? "")
        }
        .alert(
            "Rebuild this plan?",
            isPresented: Binding(
                get: { regenerationPreview != nil },
                set: { if !$0 { regenerationPreview = nil } }
            ),
            presenting: regenerationPreview
        ) { _ in
            Button("Rebuild") {
                regenerationPreview = nil
                Task { await app.planning.rebuildPlan(for: event) }
            }
            Button("Cancel", role: .cancel) { regenerationPreview = nil }
        } message: { preview in
            Text(PlanRegenerator.confirmationMessage(for: preview))
        }
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

    @State private var handoffStep: PrepStep?

    /// Nil for steps aimed at yourself — there is nobody to message.
    private func messageAction(for step: PrepStep) -> (() -> Void)? {
        guard step.audience.isContactable else { return nil }
        return {
            handoffStep = step
            Task { await handoff.begin(step: step, event: event, app: app) }
        }
    }

    /// Only the buildWork "block the working hours" rung, and only before it has done so.
    private func blockTimeAction(for step: PrepStep) -> (() -> Void)? {
        guard WorkBlockPlanner.isOfferable(step, event: event),
              step.calendarBlockIdentifier == nil
        else { return nil }
        return {
            Task { workBlockMessage = await app.createWorkBlock(for: step, event: event) }
        }
    }

    private var emptySentence: String {
        switch event.kind {
        case .unknown:
            "Forerun doesn't know what this is yet. Tell it, and it'll build the run-up."
        default:
            "There's nothing left to do before this one."
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title)
                .font(TypeRamp.eventTitle())
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(dateLine)
                .font(TypeRamp.caption())
                .foregroundStyle(Palette.muted)

            Button {
                isCorrectingKind = true
            } label: {
                HStack(spacing: 5) {
                    Text(event.kind.displayName)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(TypeRamp.micro())
                .foregroundStyle(Palette.amber)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Palette.amber.opacity(0.10), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Kind: \(event.kind.displayName)")
            .accessibilityHint("Double tap to change what kind of event this is")
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.hMargin)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private var dateLine: String {
        let date = event.isAllDay
            ? event.startDate.formatted(.dateTime.weekday(.wide).month(.wide).day())
            : event.startDate.formatted(date: .abbreviated, time: .shortened)
        return "\(date) · \(event.calendarName)"
    }

    // MARK: Timeline

    private var timeline: some View {
        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
            StepRow(
                    step: step,
                    isFirst: index == 0,
                    isLast: index == steps.count - 1,
                    onTap: { editingStep = step },
                    onDone: { Task { await app.resolve(step, as: .done) } },
                    onSkip: { Task { await app.resolve(step, as: .skipped) } },
                onSnooze: {
                    Task {
                        let moved = await app.snooze(step)
                        if !moved {
                            snoozeFailureMessage = "This step can't move any later — "
                                + "\(event.title) is too close."
                        }
                    }
                },
                onMessage: messageAction(for: step),
                onBlockTime: blockTimeAction(for: step)
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }
}

// MARK: - One rung

private struct StepRow: View {
    @Bindable var step: PrepStep
    let isFirst: Bool
    let isLast: Bool
    let onTap: () -> Void
    let onDone: () -> Void
    let onSkip: () -> Void
    let onSnooze: () -> Void
    /// Nil for steps aimed at yourself — there is nobody to message.
    var onMessage: (() -> Void)?
    /// Only the buildWork "block the working hours" rung, and only before it has done so.
    var onBlockTime: (() -> Void)?

    private var effectiveDate: Date { step.snoozedUntil ?? step.fireDate }

    private var isResolved: Bool { step.state.isResolved }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                rail
                content
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.hMargin)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isResolved {
                Button("Skip", systemImage: "xmark") { onSkip() }
                    .tint(Palette.muted)
                Button("Snooze", systemImage: "clock") { onSnooze() }
                    .tint(Palette.clay)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isResolved {
                Button("Done", systemImage: "checkmark") { onDone() }
                    .tint(Palette.amber)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.relativeLabel), for \(step.audience.displayName). \(step.effectiveCopy)")
        .accessibilityValue(stateLabel ?? "Pending")
        .accessibilityHint("Double tap to edit this step")
        .accessibilityActions {
            if !isResolved {
                Button("Mark done", action: onDone)
                Button("Skip", action: onSkip)
                Button("Snooze one day", action: onSnooze)
            }
        }
    }

    /// The rail is one hairline running the height of the row, interrupted by the step's dot.
    /// It stops short at the ends so the ladder reads as having a beginning and an end.
    private var rail: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : Palette.hairline)
                .frame(width: Metrics.railWidth, height: 10)
            Circle()
                .fill(isResolved ? Palette.hairline : Palette.forAudience(step.audience))
                .frame(width: Metrics.dotSize, height: Metrics.dotSize)
                .overlay {
                    if step.userPinnedTime {
                        Circle()
                            .stroke(Palette.ink, lineWidth: 1.5)
                            .frame(width: Metrics.dotSize + 5, height: Metrics.dotSize + 5)
                    }
                }
            Rectangle()
                .fill(isLast ? Color.clear : Palette.hairline)
                .frame(width: Metrics.railWidth)
                .frame(maxHeight: .infinity)
        }
        .frame(width: Metrics.dotSize + 6)
        .padding(.top, 4)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(step.relativeLabel)
                Text("·")
                Text(effectiveDate.formatted(date: .abbreviated, time: .shortened))
                if let stateLabel {
                    Text("·")
                    Text(stateLabel)
                }
            }
            .font(TypeRamp.micro())
            .foregroundStyle(isResolved ? Palette.hairline : Palette.muted)

            Text(step.effectiveCopy)
                .font(TypeRamp.body())
                .foregroundStyle(isResolved ? Palette.muted : Palette.ink)
                .strikethrough(step.state == .skipped, color: Palette.muted)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if step.audience.isContactable {
                Text(step.audience.displayName)
                    .font(TypeRamp.micro())
                    .foregroundStyle(Palette.forAudience(step.audience))
            }

            if !isResolved, onMessage != nil || onBlockTime != nil {
                HStack(spacing: 10) {
                    if let onMessage {
                        ActionChip(title: "Message", systemImage: "message", action: onMessage)
                    }
                    if let onBlockTime {
                        ActionChip(title: "Block the time", systemImage: "calendar.badge.plus",
                                   action: onBlockTime)
                    }
                }
                .padding(.top, 4)
            }

            if step.calendarBlockIdentifier != nil {
                Text("Blocked on your calendar")
                    .font(TypeRamp.micro())
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.vertical, Metrics.rowSpacing)
    }

    private var stateLabel: String? {
        switch step.state {
        case .done: "done"
        case .skipped: "skipped"
        case .snoozed: "snoozed"
        case .fired, .pending: nil
        }
    }
}

// MARK: - Banners and chips

private struct CompressionBanner: View {
    let droppedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This is a tight run-up")
                .font(TypeRamp.bodyEmphasis())
                .foregroundStyle(Palette.ink)
            Text(sentence)
                .font(TypeRamp.caption())
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.paperSunk, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var sentence: String {
        droppedCount > 0
            ? "Forerun squeezed the plan into the time available and left out \(droppedCount) "
                + "step\(droppedCount == 1 ? "" : "s") there wasn't room for."
            : "Forerun squeezed the plan into the time available."
    }
}

private struct KindConfirmationChip: View {
    let event: TrackedEvent
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(event.kind.confirmationPrompt)
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text("Change")
                    .font(TypeRamp.micro())
                    .foregroundStyle(Palette.amber)
            }
            .padding(12)
            .background(Palette.amber.opacity(0.08), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Double tap to pick a different kind of event")
    }
}

// MARK: - Editors

struct StepEditorSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var step: PrepStep
    let event: TrackedEvent

    @State private var draftCopy: String = ""
    @State private var draftDate: Date = .now
    @State private var draftAudience: Audience = .me
    @State private var pinTime = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What to do", text: $draftCopy, axis: .vertical)
                        .lineLimit(2...6)
                        .font(TypeRamp.body())
                } header: {
                    Text("Sentence")
                } footer: {
                    Text("Once you edit this, Forerun never overwrites it — not when the event "
                         + "moves, and not when the plan is rebuilt.")
                }

                Section {
                    DatePicker("Fires", selection: $draftDate)
                    Toggle("Keep this time", isOn: $pinTime)
                        .tint(Palette.amber)
                } footer: {
                    Text(pinTime
                         ? "This step stays exactly here. Quiet hours and the daily limit won't move it."
                         : "Forerun may shift this to avoid quiet hours or a busy day.")
                }

                Section("For") {
                    Picker("Audience", selection: $draftAudience) {
                        ForEach(Audience.allCases, id: \.self) { audience in
                            Text(audience.displayName).tag(audience)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    Button("Delete this step", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .navigationTitle("Step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Delete this step?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        await app.deleteStep(step, from: event)
                        dismiss()
                    }
                }
                Button("Keep it", role: .cancel) {}
            }
        }
        .onAppear {
            draftCopy = step.effectiveCopy
            draftDate = step.snoozedUntil ?? step.fireDate
            draftAudience = step.audience
            pinTime = step.userPinnedTime
        }
    }

    private func save() {
        // Only record an edit when the sentence actually changed. Writing `userEditedCopy` for
        // an untouched sentence would freeze it against every future improvement to the
        // playbook, which is not what the user asked for by opening the sheet.
        if draftCopy != step.effectiveCopy {
            step.userEditedCopy = draftCopy.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if draftDate != (step.snoozedUntil ?? step.fireDate) {
            step.fireDate = draftDate
            step.snoozedUntil = nil
        }
        step.audience = draftAudience
        step.userPinnedTime = pinTime
        Task { await app.stepWasEdited() }
    }
}

struct CustomStepSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    let event: TrackedEvent

    @State private var copy = ""
    @State private var fireDate = Date().addingTimeInterval(86_400)
    @State private var audience: Audience = .me

    private var isValid: Bool {
        !copy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What to do") {
                    TextField("Send the parking plan to the setup crew", text: $copy, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("When") {
                    DatePicker("Fires", selection: $fireDate)
                }
                Section("For") {
                    Picker("Audience", selection: $audience) {
                        ForEach(Audience.allCases, id: \.self) { audience in
                            Text(audience.displayName).tag(audience)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .navigationTitle("Add a step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await app.addCustomStep(
                                to: event,
                                copy: copy.trimmingCharacters(in: .whitespacesAndNewlines),
                                fireDate: fireDate,
                                audience: audience
                            )
                            dismiss()
                        }
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}

struct KindPickerSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    let event: TrackedEvent

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(EventKind.selectable, id: \.self) { kind in
                        Button {
                            Task {
                                await app.planning.confirmKind(kind, for: event)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(kind.displayName)
                                        .foregroundStyle(Palette.ink)
                                    Text(PlaybookLibrary.playbook(for: kind).stepSummary)
                                        .font(TypeRamp.caption())
                                        .foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                if kind == event.kind {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Palette.amber)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Changing this rebuilds the plan from a different playbook. Anything "
                         + "you've edited is kept.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .navigationTitle("What is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}


/// A small bordered action inside a step row. Not a card — a chip on the same surface.
private struct ActionChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(TypeRamp.micro())
                .foregroundStyle(Palette.amber)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(
                    Capsule().stroke(Palette.amber.opacity(0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Shares the rendered ladder. Plain text, so it works in any app the user already uses.
struct ShareTextSheet: View {
    let text: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.hMargin)
            }
            .background(Palette.paper)
            .navigationTitle("Share plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: text, subject: Text(title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}
