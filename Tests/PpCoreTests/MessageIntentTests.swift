import XCTest
@testable import PpCore

final class MessageIntentTests: XCTestCase {
    func testWhatsAppSayingPattern() {
        let text = "whatsapp Diya saying the launch is tomorrow"
        let intent = MessageIntentParser.parse(text)
        XCTAssertEqual(intent, .send(app: .whatsApp, contact: "Diya", text: "the launch is tomorrow"))
    }

    func testWhatsAppColonPattern() {
        let text = "send Diya a message on whatsapp: see you at noon"
        let intent = MessageIntentParser.parse(text)
        XCTAssertEqual(intent, .send(app: .whatsApp, contact: "Diya", text: "see you at noon"))
    }

    func testWhatsAppDirectWords() {
        let text = "whatsapp Diya the launch is tomorrow"
        let intent = MessageIntentParser.parse(text)
        XCTAssertEqual(intent, .send(app: .whatsApp, contact: "Diya", text: "the launch is tomorrow"))
    }

    func testMessagesTextSaying() {
        let text = "text Alex saying I will be late"
        let intent = MessageIntentParser.parse(text)
        XCTAssertEqual(intent, .send(app: .messages, contact: "Alex", text: "I will be late"))
    }

    func testMessagesTextDirect() {
        let text = "text Mom running 5 minutes late"
        let intent = MessageIntentParser.parse(text)
        XCTAssertEqual(intent, .send(app: .messages, contact: "Mom", text: "running 5 minutes late"))
    }

    func testMessageOnMessagesThat() {
        let text = "message Bob on messages that dinner is ready"
        let intent = MessageIntentParser.parse(text)
        XCTAssertEqual(intent, .send(app: .messages, contact: "Bob", text: "dinner is ready"))
    }

    func testMissingBodyIsNone() {
        let text = "whatsapp Diya"
        let intent = MessageIntentParser.parse(text)
        XCTAssertEqual(intent, .none)
    }

    func testEmptyIsNone() {
        XCTAssertEqual(MessageIntentParser.parse(""), .none)
        XCTAssertEqual(MessageIntentParser.parse("   "), .none)
    }
}
