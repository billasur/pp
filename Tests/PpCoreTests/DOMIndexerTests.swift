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

    func testDualTransportParityAndOpaquePaymentIframe() {
        // Shared fixture: CDP dictionary and Extension dictionary representing same DOM
        let cdpDict: [String: Any] = [
            "id": "link-1",
            "tag": "a",
            "role": "link",
            "accessibleName": "Documentation",
            "rect": ["x": 10.0, "y": 20.0, "width": 80.0, "height": 25.0],
            "isVisible": true,
            "isInteractive": true
        ]
        let extDict: [String: Any] = [
            "backendNodeId": 1,
            "nodeName": "A",
            "role": "link",
            "name": "Documentation",
            "rect": ["left": 10.0, "top": 20.0, "w": 80.0, "h": 25.0],
            "isVisible": true,
            "isInteractive": true
        ]

        let cdpInput = DOMIndexer.DOMElementInput(dictionary: cdpDict)!
        let extInput = DOMIndexer.DOMElementInput(dictionary: extDict)!

        let cdpIndex = DOMIndexer.index(elements: [cdpInput])
        let extIndex = DOMIndexer.index(elements: [extInput])

        XCTAssertEqual(cdpIndex.candidates.count, 1)
        XCTAssertEqual(extIndex.candidates.count, 1)
        XCTAssertEqual(cdpIndex.candidates[0].label, extIndex.candidates[0].label)
        XCTAssertEqual(cdpIndex.candidates[0].role, extIndex.candidates[0].role)

        // Privacy: verify payment iframe and autocomplete=cc-* are unconditionally opaque
        let paymentIframeDict: [String: Any] = [
            "id": "iframe-payment",
            "tag": "iframe",
            "role": "region",
            "accessibleName": "Stripe Payment Element",
            "isPaymentOrCardDescendant": true,
            "isVisible": true,
            "isInteractive": true
        ]
        let paymentInput = DOMIndexer.DOMElementInput(dictionary: paymentIframeDict)!
        let paymentIndex = DOMIndexer.index(elements: [paymentInput])

        XCTAssertTrue(paymentIndex.opaqueElementIDs.contains("iframe-payment"))
        XCTAssertTrue(paymentIndex.candidates.isEmpty, "Payment iframe must never appear in candidate list")
    }
}
