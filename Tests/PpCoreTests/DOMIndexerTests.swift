import XCTest
import CoreGraphics
@testable import PpCore

final class DOMIndexerTests: XCTestCase {
    func testDocumentationLinkAndSearchIndexing() {
        let elements = [
            DOMIndexer.DOMElementInput(
                id: "btn-docs",
                tag: "a",
                role: "link",
                accessibleName: "Documentation",
                placeholder: nil,
                textContent: "Docs",
                isVisible: true,
                isInteractive: true,
                rect: CGRect(x: 10, y: 10, width: 100, height: 30)
            ),
            DOMIndexer.DOMElementInput(
                id: "input-search",
                tag: "input",
                role: "searchbox",
                accessibleName: "Search",
                placeholder: "Search documentation",
                textContent: nil,
                isVisible: true,
                isInteractive: true,
                rect: CGRect(x: 120, y: 10, width: 200, height: 30)
            ),
            DOMIndexer.DOMElementInput(
                id: "pwd-field",
                tag: "input",
                role: "textbox",
                accessibleName: "Password",
                placeholder: nil,
                textContent: nil,
                isVisible: true,
                isInteractive: true,
                rect: CGRect(x: 10, y: 50, width: 200, height: 30),
                inputType: "password"
            ),
            DOMIndexer.DOMElementInput(
                id: "card-field",
                tag: "input",
                role: "textbox",
                accessibleName: "Card number",
                placeholder: "XXXX-XXXX",
                textContent: nil,
                isVisible: true,
                isInteractive: true,
                rect: CGRect(x: 10, y: 90, width: 200, height: 30),
                autocomplete: "cc-number"
            )
        ]

        let result = DOMIndexer.index(elements: elements)

        // Password and card fields must be recognized as opaque and dropped from candidates
        XCTAssertTrue(result.opaqueElementIDs.contains("pwd-field"))
        XCTAssertTrue(result.opaqueElementIDs.contains("card-field"))
        XCTAssertFalse(result.candidates.contains { $0.id == "pwd-field" })
        XCTAssertFalse(result.candidates.contains { $0.id == "card-field" })

        // Documentation link and Search must be present in indexed candidates
        XCTAssertTrue(result.candidates.contains { $0.id == "btn-docs" && $0.label == "Documentation" })
        XCTAssertTrue(result.candidates.contains { $0.id == "input-search" && $0.label == "Search" })

        // Index wire string format checks
        XCTAssertTrue(result.indexedWireString.contains("label=\"Documentation\""))
        XCTAssertTrue(result.indexedWireString.contains("label=\"Search\""))
    }
}
