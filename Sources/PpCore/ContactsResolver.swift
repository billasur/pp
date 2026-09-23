import Foundation
#if canImport(Contacts)
import Contacts
#endif

public struct ResolvedContact: Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let phoneNumbers: [String]
    public let emailAddresses: [String]

    public init(
        identifier: String,
        displayName: String,
        phoneNumbers: [String] = [],
        emailAddresses: [String] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
    }
}

public protocol ContactProviding: Sendable {
    func search(name: String) async -> [ResolvedContact]
}

public final class SystemContactProvider: ContactProviding, @unchecked Sendable {
    public static let shared = SystemContactProvider()

    #if canImport(Contacts)
    private let store = CNContactStore()
    #endif

    public init() {}

    public func search(name: String) async -> [ResolvedContact] {
        #if canImport(Contacts)
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else {
            return []
        }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]

        let predicate = CNContact.predicateForContacts(matchingName: name)
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            return contacts.map { c in
                let given = c.givenName
                let family = c.familyName
                let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
                let display = full.isEmpty ? name : full
                let phones = c.phoneNumbers.map { $0.value.stringValue }
                let emails = c.emailAddresses.map { String($0.value) }
                return ResolvedContact(
                    identifier: c.identifier,
                    displayName: display,
                    phoneNumbers: phones,
                    emailAddresses: emails
                )
            }
        } catch {
            return []
        }
        #else
        return []
        #endif
    }
}

public enum ContactsResolutionResult: Equatable, Sendable {
    case exact(ResolvedContact)
    case ambiguous([ResolvedContact])
    case notFound(name: String)
}

public enum ContactsResolver {
    public static func resolve(name: String, provider: ContactProviding = SystemContactProvider.shared) async -> ContactsResolutionResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound(name: "") }

        let candidates = await provider.search(name: trimmed)
        if candidates.isEmpty {
            return .notFound(name: trimmed)
        }

        // Exact match check (case-insensitive)
        let exactMatches = candidates.filter { $0.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
        if exactMatches.count == 1 {
            return .exact(exactMatches[0])
        }

        if candidates.count == 1 {
            return .exact(candidates[0])
        }

        return .ambiguous(candidates)
    }
}
