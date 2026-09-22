import Foundation
import CoreGraphics

/// Truncated DOM index builder for browser elements (zero screenshot, element indexing).
/// Indexes interactive and visible elements, respecting privacy (opaque fields for passwords/payments).
public enum DOMIndexer {
    public struct DOMElementInput: Sendable {
        public let id: String
        public let tag: String
        public let role: String?
        public let accessibleName: String?
        public let placeholder: String?
        public let textContent: String?
        public let isVisible: Bool
        public let isInteractive: Bool
        public let rect: CGRect
        public let inputType: String?
        public let autocomplete: String?
        public let isPaymentOrCardDescendant: Bool

        public init(
            id: String,
            tag: String,
            role: String? = nil,
            accessibleName: String? = nil,
            placeholder: String? = nil,
            textContent: String? = nil,
            isVisible: Bool = true,
            isInteractive: Bool = true,
            rect: CGRect = .zero,
            inputType: String? = nil,
            autocomplete: String? = nil,
            isPaymentOrCardDescendant: Bool = false
        ) {
            self.id = id
            self.tag = tag
            self.role = role
            self.accessibleName = accessibleName
            self.placeholder = placeholder
            self.textContent = textContent
            self.isVisible = isVisible
            self.isInteractive = isInteractive
            self.rect = rect
            self.inputType = inputType
            self.autocomplete = autocomplete
            self.isPaymentOrCardDescendant = isPaymentOrCardDescendant
        }
    }

    public struct IndexResult: Equatable, Sendable {
        public let candidates: [UICandidate]
        public let opaqueElementIDs: Set<String>
        public let indexedWireString: String

        public init(candidates: [UICandidate], opaqueElementIDs: Set<String>, indexedWireString: String) {
            self.candidates = candidates
            self.opaqueElementIDs = opaqueElementIDs
            self.indexedWireString = indexedWireString
        }
    }

    /// Tests if an input is sensitive/opaque (passwords, credit cards, payment iframes).
    public static func isOpaque(element: DOMElementInput) -> Bool {
        if element.isPaymentOrCardDescendant { return true }
        if let type = element.inputType?.lowercased(), type == "password" { return true }
        if let auto = element.autocomplete?.lowercased(), auto.hasPrefix("cc-") || auto.contains("credit-card") || auto.contains("password") {
            return true
        }
        let checkText = "\(element.accessibleName ?? "") \(element.placeholder ?? "") \(element.textContent ?? "")"
        if PrivacyFilter.isSensitiveField(checkText) {
            return true
        }
        return false
    }

    /// Indexes DOM elements with ranking and truncation up to Shortlister.defaultLimit (16).
    public static func index(elements: [DOMElementInput], limit: Int = Shortlister.defaultLimit) -> IndexResult {
        var opaqueIDs: Set<String> = []
        var rawCandidates: [(candidate: UICandidate, rect: CGRect)] = []

        for el in elements {
            guard el.isVisible else { continue }

            if isOpaque(element: el) {
                opaqueIDs.insert(el.id)
                // Opaque fields are never included in readable interactive candidate list
                continue
            }

            guard el.isInteractive else { continue }

            // Label precedence: accessible name -> placeholder -> text content (truncated)
            let chosenLabel: String
            if let acc = el.accessibleName, !acc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chosenLabel = acc.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let ph = el.placeholder, !ph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chosenLabel = ph.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let tc = el.textContent, !tc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chosenLabel = String(tc.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            } else {
                continue
            }

            let role: UICandidate.Role
            let roleStr = (el.role ?? el.tag).lowercased()
            if roleStr.contains("button") {
                role = .button
            } else if roleStr.contains("link") || roleStr == "a" {
                role = .link
            } else if roleStr.contains("search") || roleStr.contains("text") || roleStr == "input" || roleStr == "textarea" {
                role = .textField
            } else if roleStr.contains("tab") {
                role = .tab
            } else if roleStr.contains("menuitem") {
                role = .menuItem
            } else if roleStr.contains("check") {
                role = .checkbox
            } else if roleStr.contains("radio") {
                role = .radioButton
            } else {
                role = .other
            }

            let detail = "tag=\(el.tag) role=\(roleStr) rect=\(Int(el.rect.origin.x)),\(Int(el.rect.origin.y)),\(Int(el.rect.size.width)),\(Int(el.rect.size.height))"
            let candidate = UICandidate(id: el.id, label: chosenLabel, detail: detail, role: role)
            rawCandidates.append((candidate, el.rect))
        }

        // Rank and cap candidates at limit
        let rankedCandidates = Shortlister.rank(rawCandidates.map(\.candidate), command: "", options: .init(limit: limit))

        // Wire contract representation: [#12 role=searchbox label="Search" in=viewport]
        let wire = rankedCandidates.enumerated().map { index, c in
            "[#\(index + 1) label=\"\(c.label)\"]"
        }.joined(separator: ", ")

        // Map back to UICandidates
        let idMap = Dictionary(uniqueKeysWithValues: rawCandidates.map { ($0.candidate.id, $0.candidate) })
        let finalCandidates = rankedCandidates.compactMap { idMap[$0.id] }

        return IndexResult(candidates: finalCandidates, opaqueElementIDs: opaqueIDs, indexedWireString: wire)
    }
}
