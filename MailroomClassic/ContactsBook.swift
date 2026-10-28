// The people in the Mac's Contacts app (including any Google or iCloud contacts
// you've added under System Settings → Internet Accounts). The To and Cc fields
// suggest them as you type, the reading pane shows their photos, and "Add to
// Contacts" saves a sender there. It uses Contacts, Apple's built-in framework
// for the address book. macOS asks you once for permission; if you say no,
// everything else works as before.

import AppKit
import Contacts
import Observation

// One email address from Contacts, with the person's name and photo.
// (`nonisolated` and `Sendable`: built on a background thread, then handed over.)
nonisolated struct ContactAddress: Sendable {
    let name: String?
    let address: String
    let photo: Data?   // a small version of the contact's picture, if it has one
}

// `@Observable`, so views showing photos or the Add button redraw once contacts
// load or change. There's one shared copy for the whole app: `ContactsBook.shared`.
@Observable
final class ContactsBook {
    static let shared = ContactsBook()

    // Every address in Contacts, as people you could email.
    private(set) var addresses: [MailAddress] = []
    // Photos and "is this person in Contacts?", by lowercase address.
    private var photos: [String: NSImage] = [:]
    private var knownAddresses: Set<String> = []
    // False until you've allowed access (and if you haven't, nothing here is used).
    private(set) var hasAccess = false

    private let contactStore = CNContactStore()
    private var isWatchingForChanges = false

    // Asks for permission (macOS only shows the question the first time), then
    // loads everyone. Reloads by itself whenever Contacts changes.
    func load() async {
        // `try?`: an error just means no access.
        hasAccess = (try? await contactStore.requestAccess(for: .contacts)) == true
        guard hasAccess else { return }
        if !isWatchingForChanges {
            isWatchingForChanges = true
            NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { _ in
                Task { @MainActor in await ContactsBook.shared.load() }
            }
        }
        // Reading every contact can take a moment, so it runs on a background thread
        // (`Task.detached`), leaving the app responsive.
        let found = await Task.detached { Self.readAllAddresses() }.value
        addresses = found.map { MailAddress(name: $0.name, address: $0.address) }
        knownAddresses = Set(found.map { $0.address.lowercased() })
        photos = [:]
        for entry in found {
            if let data = entry.photo, let image = NSImage(data: data) {
                photos[entry.address.lowercased()] = image
            }
        }
    }

    // Each contact's email addresses, with their name and photo. Returns [] if Contacts can't be read.
    nonisolated private static func readAllAddresses() -> [ContactAddress] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),   // whatever a full name needs
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        var found: [ContactAddress] = []
        // `enumerateContacts` calls the closure once per contact.
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            // The full name ("Sarah Miller"), or the company for a company card.
            let fullName = CNContactFormatter.string(from: contact, style: .fullName)
            let name = (fullName?.isEmpty == false ? fullName : nil) ?? (contact.organizationName.isEmpty ? nil : contact.organizationName)
            for email in contact.emailAddresses {
                found.append(ContactAddress(name: name, address: email.value as String, photo: contact.thumbnailImageData))
            }
        }
        return found
    }

    // The contact's photo for an email address, if they're in Contacts and have one.
    func photo(for address: String) -> NSImage? {
        photos[address.lowercased()]
    }

    // Whether an email address belongs to someone in Contacts.
    func contains(_ address: String) -> Bool {
        knownAddresses.contains(address.lowercased())
    }

    // Saves a new contact with this name and address. Throws if Contacts refuses.
    func add(_ person: MailAddress) throws {
        let contact = CNMutableContact()
        // Splits "Sarah Miller" into first and last name the way Contacts expects.
        if let name = person.name, !name.isEmpty {
            let parts = PersonNameComponentsFormatter().personNameComponents(from: name)
            contact.givenName = parts?.givenName ?? name
            contact.familyName = parts?.familyName ?? ""
        }
        contact.emailAddresses = [CNLabeledValue(label: CNLabelOther, value: person.address as NSString)]
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)   // nil: your default Contacts account
        try contactStore.execute(request)
        // Show the change straight away; Contacts' change notice then reloads everything.
        knownAddresses.insert(person.address.lowercased())
        addresses.append(person)
    }
}
