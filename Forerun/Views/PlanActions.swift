import Contacts
import ForerunCore
import MessageUI
import SwiftData
import SwiftUI

// MARK: - People

/// The people a leader or participant step can hand off to.
///
/// Adding someone uses the out-of-process contact picker, which needs no Contacts permission at
/// all. Permission is only asked for at the moment a message is actually composed, and only for
/// people the user already chose.
struct EventPeopleSection: View {
    @Environment(AppEnvironment.self) private var app
    @Bindable var event: TrackedEvent
    @State private var isPickingContacts = false
    @State private var pickingAudience: Audience = .leaders

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PEOPLE")
                    .font(TypeRamp.micro())
                    .tracking(0.8)
                    .foregroundStyle(Palette.muted)
                Spacer()
                Menu {
                    ForEach(Audience.allCases.filter(\.isContactable), id: \.self) { audience in
                        Button("Add \(audience.displayName.lowercased())") {
                            pickingAudience = audience
                            isPickingContacts = true
                        }
                    }
                } label: {
                    Text("Add")
                        .font(TypeRamp.micro())
                        .foregroundStyle(Palette.amber)
                }
            }

            if event.contacts.isEmpty {
                Text("No one added yet. Adding your team leads lets a step open a message with "
                     + "them already in it.")
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(event.contacts.sorted { $0.addedAt < $1.addedAt }) { contact in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Palette.forAudience(contact.audience))
                            .frame(width: 7, height: 7)
                        Text(contact.displayName)
                            .font(TypeRamp.body())
                            .foregroundStyle(Palette.ink)
                        Text(contact.audience.displayName)
                            .font(TypeRamp.micro())
                            .foregroundStyle(Palette.muted)
                        Spacer()
                        Button {
                            app.removeContact(contact, from: event)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Palette.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(contact.displayName)")
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.hMargin)
        .padding(.vertical, 12)
        .sheet(isPresented: $isPickingContacts) {
            ContactPicker { contacts in
                app.addContacts(
                    contacts.map { ($0.identifier, CNContactFormatter.string(from: $0, style: .fullName) ?? "Someone") },
                    to: event,
                    audience: pickingAudience
                )
                isPickingContacts = false
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Handoff

/// Everything the Message button needs, resolved and presented.
@MainActor
@Observable
final class HandoffController {
    enum Sheet: Identifiable {
        case message(recipients: [String], body: String)
        case mail(recipients: [String], subject: String, body: String)

        var id: String {
            switch self {
            case .message(let recipients, _): "message-\(recipients.joined(separator: ","))"
            case .mail(let recipients, _, _): "mail-\(recipients.joined(separator: ","))"
            }
        }
    }

    var sheet: Sheet?
    var message: String?
    private(set) var isPreparing = false

    /// Resolves the recipients, asks for Contacts only if it has to, and picks the composer that
    /// can actually reach them.
    func begin(step: PrepStep, event: TrackedEvent, app: AppEnvironment) async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        let people = event.contacts.filter { contact in
            step.audience.isLeadership ? contact.audience.isLeadership : contact.audience.isAudienceSide
        }
        let fallback = people.isEmpty ? event.contacts : people
        guard !fallback.isEmpty else {
            message = "Add the people this step is for, then Forerun can open a message with "
                + "them already in it."
            return
        }

        if ContactResolver.authorizationStatus != .authorized {
            guard await ContactResolver.requestAccess() else {
                message = "Forerun needs permission to look up the numbers for the people you "
                    + "picked. You can turn that on in Settings."
                return
            }
        }

        let resolved = await ContactResolver.resolve(fallback)
        let body = await app.draftMessage(for: step, event: event)

        if !resolved.phoneNumbers.isEmpty, MessageComposer.canSend {
            sheet = .message(recipients: resolved.phoneNumbers, body: body)
        } else if !resolved.emails.isEmpty, MailComposer.canSend {
            sheet = .mail(recipients: resolved.emails, subject: event.title, body: body)
        } else if !resolved.missing.isEmpty {
            message = "Forerun couldn't find a number or an email for "
                + resolved.missing.joined(separator: ", ") + "."
        } else {
            message = "This iPhone can't send messages."
        }
    }
}

// MARK: - Scratchpad

/// Notes, links and a photo of the whiteboard, attached to the event.
///
/// The friction this removes: "send leads the schedule" arrives, and then you go hunting for the
/// schedule. The notification's deep link lands here.
struct ScratchpadSection: View {
    @Environment(AppEnvironment.self) private var app
    @Bindable var event: TrackedEvent

    @State private var isAddingNote = false
    @State private var isAddingLink = false
    @State private var draftText = ""
    @State private var draftURL = ""
    @State private var photoItem: PhotosPickerItemBox?
    @State private var viewingPhoto: ScratchpadItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MATERIAL")
                    .font(TypeRamp.micro())
                    .tracking(0.8)
                    .foregroundStyle(Palette.muted)
                Spacer()
                Menu {
                    Button("Note", systemImage: "text.alignleft") {
                        draftText = ""
                        isAddingNote = true
                    }
                    Button("Link", systemImage: "link") {
                        draftText = ""
                        draftURL = ""
                        isAddingLink = true
                    }
                    Button("Photo", systemImage: "camera") {
                        photoItem = PhotosPickerItemBox()
                    }
                } label: {
                    Text("Add")
                        .font(TypeRamp.micro())
                        .foregroundStyle(Palette.amber)
                }
            }

            if event.scratchpad.isEmpty {
                Text("Nothing attached. A photo of the whiteboard or a link to the schedule lands "
                     + "here, so it's in front of you when the reminder fires.")
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(event.scratchpad.sorted { $0.sortOrder < $1.sortOrder }) { item in
                    ScratchpadRow(item: item) {
                        if item.kind == .photo { viewingPhoto = item }
                    } onDelete: {
                        app.removeScratchpadItem(item, from: event)
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.hMargin)
        .padding(.vertical, 12)
        .alert("Note", isPresented: $isAddingNote) {
            TextField("What you need to remember", text: $draftText)
            Button("Add") {
                app.addNote(draftText, to: event)
                draftText = ""
            }
            Button("Cancel", role: .cancel) { draftText = "" }
        }
        .alert("Link", isPresented: $isAddingLink) {
            TextField("https://…", text: $draftURL)
                .textInputAutocapitalization(.never)
            TextField("What it is (optional)", text: $draftText)
            Button("Add") {
                app.addLink(draftURL, title: draftText, to: event)
                draftURL = ""
                draftText = ""
            }
            Button("Cancel", role: .cancel) {
                draftURL = ""
                draftText = ""
            }
        }
        .sheet(item: $photoItem) { _ in
            PhotoCaptureSheet { data in
                app.addPhoto(data, to: event)
                photoItem = nil
            }
        }
        .sheet(item: $viewingPhoto) { item in
            PhotoViewer(item: item)
        }
    }
}

/// Identifiable wrapper so `.sheet(item:)` can drive the picker.
struct PhotosPickerItemBox: Identifiable {
    let id = UUID()
}

private struct ScratchpadRow: View {
    @Bindable var item: ScratchpadItem
    let onTap: () -> Void
    let onDelete: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .frame(width: 16)

            Button {
                if item.kind == .link, let url = item.url {
                    openURL(url)
                } else {
                    onTap()
                }
            } label: {
                Text(item.summary)
                    .font(TypeRamp.body())
                    .foregroundStyle(item.kind == .link ? Palette.amber : Palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.summary)")
        }
    }

    private var icon: String {
        switch item.kind {
        case .note: "text.alignleft"
        case .link: "link"
        case .photo: "photo"
        }
    }
}

private struct PhotoViewer: View {
    let item: ScratchpadItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let data = item.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(item.text.isEmpty ? "Attached photo" : item.text)
                } else {
                    EmptyStateSentence(sentence: "That photo is no longer available.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.paper)
            .navigationTitle(item.text.isEmpty ? "Photo" : item.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Camera capture for the whiteboard.
struct PhotoCaptureSheet: UIViewControllerRepresentable {
    let onCaptured: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // The camera is the point — a whiteboard photo is taken, not found. The library is the
        // fallback on a device with no camera.
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera
            : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCaptured: onCaptured, onCancel: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCaptured: (Data) -> Void
        private let onCancel: () -> Void

        init(onCaptured: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCaptured = onCaptured
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            // Downscaled and JPEG-compressed before storage. A full-resolution capture is
            // several megabytes and nothing here needs more than legible handwriting.
            onCaptured(ScratchpadImage.encode(image))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

enum ScratchpadImage {
    static let maxDimension: CGFloat = 2_000
    static let compression: CGFloat = 0.7

    static func encode(_ image: UIImage) -> Data {
        let scaled = downscale(image)
        return scaled.jpegData(compressionQuality: compression) ?? Data()
    }

    static func downscale(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
