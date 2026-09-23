import Foundation

public enum MessagingApp: String, Sendable, Equatable {
    case whatsApp = "WhatsApp"
    case messages = "Messages"
}

public enum MessageIntent: Equatable, Sendable {
    case send(app: MessagingApp, contact: String, text: String)
    case none

    public var isActionable: Bool {
        if case .send = self { return true }
        return false
    }
}

public enum MessageIntentParser {
    public static func parse(_ text: String) -> MessageIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'"))
        guard !trimmed.isEmpty else { return .none }
        let lower = trimmed.lowercased()

        // 1. "whatsapp <contact> saying <text>" / "whatsapp <contact> <text>"
        if lower.hasPrefix("whatsapp ") {
            let rest = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerRest = rest.lowercased()
            if let sayingRange = lowerRest.range(of: " saying ") {
                let contact = String(rest[..<sayingRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let body = String(rest[sayingRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !contact.isEmpty && !body.isEmpty {
                    return .send(app: .whatsApp, contact: contact, text: body)
                }
            } else if let colonRange = lowerRest.range(of: ":") {
                let contact = String(rest[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let body = String(rest[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !contact.isEmpty && !body.isEmpty {
                    return .send(app: .whatsApp, contact: contact, text: body)
                }
            } else {
                // "whatsapp Diya the launch is tomorrow" -> first word is contact
                let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
                if words.count == 2 {
                    return .send(app: .whatsApp, contact: words[0], text: words[1])
                }
            }
        }

        // 2. "message <contact> on whatsapp saying <text>" / "send <contact> a message on whatsapp: <text>"
        if lower.hasPrefix("message ") || lower.hasPrefix("send ") {
            let app: MessagingApp = (lower.contains("whatsapp") || lower.contains("whats app")) ? .whatsApp : .messages

            if let onRange = lower.range(of: " on whatsapp") ?? lower.range(of: " on messages") ?? lower.range(of: " on imessage") {
                var prefixPart = String(trimmed[..<onRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                // strip leading "message " or "send "
                if prefixPart.lowercased().hasPrefix("message ") {
                    prefixPart = String(prefixPart.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if prefixPart.lowercased().hasPrefix("send ") {
                    prefixPart = String(prefixPart.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // strip "a message"
                if prefixPart.lowercased().hasSuffix(" a message") {
                    prefixPart = String(prefixPart.dropLast(10)).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                let contact = prefixPart
                let afterOn = String(trimmed[onRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let lowerAfter = afterOn.lowercased()

                var body = ""
                if lowerAfter.hasPrefix("saying ") {
                    body = String(afterOn.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if afterOn.hasPrefix(":") {
                    body = String(afterOn.dropFirst(1)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if lowerAfter.hasPrefix("that ") {
                    body = String(afterOn.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    body = afterOn
                }

                if !contact.isEmpty && !body.isEmpty {
                    return .send(app: app, contact: contact, text: body)
                }
            }
        }

        // 3. "text <contact> <text>" / "text <contact> saying <text>"
        if lower.hasPrefix("text ") {
            let rest = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerRest = rest.lowercased()
            if let sayingRange = lowerRest.range(of: " saying ") {
                let contact = String(rest[..<sayingRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let body = String(rest[sayingRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !contact.isEmpty && !body.isEmpty {
                    return .send(app: .messages, contact: contact, text: body)
                }
            } else {
                let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
                if words.count == 2 {
                    return .send(app: .messages, contact: words[0], text: words[1])
                }
            }
        }

        return .none
    }
}
