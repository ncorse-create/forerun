import Contacts
import ContactsUI
import ForerunCore
import Foundation
import MessageUI
import SwiftUI

/// Picks people for an event.
///
/// Uses `CNContactPickerViewController`, which runs **out of process** and hands back only what
/// the user selected — so it needs no Contacts permission at all. That is strictly better than
/// asking: the app never gains the ability to read the address book, and there is no permission
/// prompt to decline. Only the identifier and a display name are kept.
struct ContactPicker: UIViewControllerRepresentable {
    let onPicked: ([CNContact]) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Only people with a phone number can receive a message.
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let onPicked: ([CNContact]) -> Void

        init(onPicked: @escaping ([CNContact]) -> Void) {
            self.onPicked = onPicked
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            onPicked(contacts)
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPicked([contact])
        }
    }
}

/// The message compose sheet, pre-filled.
///
/// iOS cannot send an SMS programmatically and Forerun does not pretend otherwise: the sheet
/// opens with the recipients and a draft, and the user taps send. Nothing in the app or its
/// store listing describes this as automatic sending.
struct MessageComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onFinish: (MessageComposeResult) -> Void

    static var canSend: Bool { MFMessageComposeViewController.canSendText() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onFinish: (MessageComposeResult) -> Void

        init(onFinish: @escaping (MessageComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            onFinish(result)
        }
    }
}

/// Mail, for contacts with no mobile number.
struct MailComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    let onFinish: (MFMailComposeResult) -> Void

    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.setToRecipients(recipients)
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        controller.mailComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: (MFMailComposeResult) -> Void

        init(onFinish: @escaping (MFMailComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: (any Error)?
        ) {
            onFinish(result)
        }
    }
}

/// Resolves stored contact identifiers into the numbers a compose sheet needs.
///
/// Forerun stores only identifiers and display names, so the actual phone number is fetched at
/// compose time. That fetch **does** need Contacts permission — but only for people the user
/// already picked, and only at the moment they tap Message.
@MainActor
enum ContactResolver {
    struct Resolved: Sendable {
        var phoneNumbers: [String]
        var emails: [String]
        var missing: [String]
    }

    static var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    static func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    static func resolve(_ contacts: [EventContact]) async -> Resolved {
        let store = CNContactStore()
        let keys: [any CNKeyDescriptor] = [
            CNContactPhoneNumbersKey as any CNKeyDescriptor,
            CNContactEmailAddressesKey as any CNKeyDescriptor,
            CNContactGivenNameKey as any CNKeyDescriptor,
            CNContactFamilyNameKey as any CNKeyDescriptor
        ]

        var phoneNumbers: [String] = []
        var emails: [String] = []
        var missing: [String] = []

        for contact in contacts {
            guard let record = try? store.unifiedContact(
                withIdentifier: contact.contactIdentifier,
                keysToFetch: keys
            ) else {
                missing.append(contact.displayName)
                continue
            }
            if let number = preferredNumber(from: record) {
                phoneNumbers.append(number)
            } else if let email = record.emailAddresses.first?.value as String? {
                emails.append(email)
            } else {
                missing.append(contact.displayName)
            }
        }
        return Resolved(phoneNumbers: phoneNumbers, emails: emails, missing: missing)
    }

    /// Mobile first, then whatever else is there. Texting someone's landline is a wasted step.
    private static func preferredNumber(from contact: CNContact) -> String? {
        let mobile = contact.phoneNumbers.first {
            $0.label == CNLabelPhoneNumberMobile || $0.label == CNLabelPhoneNumberiPhone
        }
        return (mobile ?? contact.phoneNumbers.first)?.value.stringValue
    }
}
