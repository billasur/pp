import XCTest
@testable import PpCore

private struct MockContactProvider: ContactProviding {
    let contacts: [ResolvedContact]

    func search(name: String) async -> [ResolvedContact] {
        contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(name)
        }
    }
}

final class ContactsResolverTests: XCTestCase {
    func testExactMatchResolvesCleanly() async {
        let diya = ResolvedContact(identifier: "1", displayName: "Diya", phoneNumbers: ["+1234567890"])
        let provider = MockContactProvider(contacts: [diya])

        let result = await ContactsResolver.resolve(name: "Diya", provider: provider)
        XCTAssertEqual(result, .exact(diya))
    }

    func testAmbiguousContactsReturnsCandidates() async {
        let alex1 = ResolvedContact(identifier: "1", displayName: "Alex Smith", phoneNumbers: ["+111"])
        let alex2 = ResolvedContact(identifier: "2", displayName: "Alex Jones", phoneNumbers: ["+222"])
        let provider = MockContactProvider(contacts: [alex1, alex2])

        let result = await ContactsResolver.resolve(name: "Alex", provider: provider)
        if case .ambiguous(let candidates) = result {
            XCTAssertEqual(candidates.count, 2)
        } else {
            XCTFail("Expected ambiguous result for Alex, got \(result)")
        }
    }

    func testUnknownContactReturnsNotFound() async {
        let provider = MockContactProvider(contacts: [])
        let result = await ContactsResolver.resolve(name: "NonexistentPerson", provider: provider)
        XCTAssertEqual(result, .notFound(name: "NonexistentPerson"))
    }
}
