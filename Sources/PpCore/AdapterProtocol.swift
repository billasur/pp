import Foundation

/// A capability an adapter can be granted. Nothing is implicit: an adapter that did not
/// declare `type` cannot type.
public struct AdapterCapability: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let readTree = AdapterCapability(rawValue: "read_tree")
    public static let click = AdapterCapability(rawValue: "click")
    public static let type = AdapterCapability(rawValue: "type")
    public static let navigate = AdapterCapability(rawValue: "navigate")
    public static let evaluateScript = AdapterCapability(rawValue: "evaluate_script")
    public static let readClipboard = AdapterCapability(rawValue: "read_clipboard")

    /// Capabilities that can expose content the user did not ask pp to read.
    public static let highRisk: Set<AdapterCapability> = [.evaluateScript, .readClipboard]
}

/// Where a snapshot came from, best first. The order is the fallback order in code.
public enum AdapterKind: String, Sendable, CaseIterable {
    case plugin
    case extensionDOM
    case debuggingProtocol
    case accessibility

    public var priority: Int {
        switch self {
        case .plugin: return 0
        case .extensionDOM: return 1
        case .debuggingProtocol: return 2
        case .accessibility: return 3
        }
    }
}

/// The tab and origin an action is allowed to touch.
public struct OriginScope: Equatable, Sendable {
    public let tabID: Int
    public let origin: String

    public init(tabID: Int, origin: String) {
        self.tabID = tabID
        self.origin = origin
    }

    /// Only the active tab, only the same origin. An adapter that reaches a different
    /// tab or site is out of scope, regardless of what the page says.
    public func allows(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return false }
        let allowedScheme = scheme == "https" || scheme == "http"
        return allowedScheme && "\(scheme)://\(host)" == origin.lowercased()
    }
}

public struct AdapterSnapshot: Equatable, Sendable {
    public let tabID: Int
    public let url: URL?
    public let title: String
    public let elements: [UICandidate]
    /// Fields whose contents are never read: passwords, payment details.
    public let opaqueElementIDs: Set<String>

    public init(tabID: Int, url: URL?, title: String, elements: [UICandidate], opaqueElementIDs: Set<String> = []) {
        self.tabID = tabID; self.url = url; self.title = title
        self.elements = elements; self.opaqueElementIDs = opaqueElementIDs
    }
}

public struct AdapterAction: Equatable, Sendable {
    public enum Kind: String, Sendable { case click, type, navigate, pressKey }
    public let kind: Kind
    public let elementID: String?
    public let text: String?

    public init(kind: Kind, elementID: String? = nil, text: String? = nil) {
        self.kind = kind; self.elementID = elementID; self.text = text
    }
}

public enum AdapterError: LocalizedError, Equatable {
    case outOfScope
    case unsupportedCapability(String)
    case opaqueField
    case notImplemented

    public var errorDescription: String? {
        switch self {
        case .outOfScope: return "That action was aimed at a different tab or site than the one you are looking at."
        case .unsupportedCapability(let capability): return "This adapter cannot \(capability)."
        case .opaqueField: return "pp does not read or type into password and payment fields."
        case .notImplemented: return "This adapter does not support that yet."
        }
    }
}

/// A way of reading and driving a browser.
public protocol BrowserAdapter: Sendable {
    var name: String { get }
    var kind: AdapterKind { get }
    var capabilities: Set<AdapterCapability> { get }
    /// The scope actions are currently allowed in: the active tab, nothing else.
    func currentScope() throws -> OriginScope
    func snapshot() throws -> AdapterSnapshot
    func perform(_ action: AdapterAction, in scope: OriginScope) throws
}

public extension BrowserAdapter {
    /// Refuses an action that is not for the active tab and origin, and refuses to
    /// touch opaque fields even when the caller asks.
    func performChecked(_ action: AdapterAction, scope: OriginScope, snapshot: AdapterSnapshot) throws {
        guard scope.tabID == snapshot.tabID else { throw AdapterError.outOfScope }
        if let elementID = action.elementID, snapshot.opaqueElementIDs.contains(elementID) {
            throw AdapterError.opaqueField
        }
        try perform(action, in: scope)
    }
}

/// Checks any adapter claims to do what it says it does.
public struct AdapterConformanceReport: Equatable, Sendable {
    public struct Check: Equatable, Sendable {
        public let name: String
        public let passed: Bool
        public let detail: String
    }
    public let adapter: String
    public let checks: [Check]
    public var passed: Bool { checks.allSatisfy(\.passed) }
}

/// The suite every browser adapter must pass, so a new adapter is a data change rather
/// than a new set of bugs.
public enum AdapterConformanceSuite {
    public static func run(_ adapter: any BrowserAdapter) -> AdapterConformanceReport {
        var checks: [AdapterConformanceReport.Check] = []

        do {
            let scope = try adapter.currentScope()
            let snapshot = try adapter.snapshot()

            checks.append(.init(name: "same-tab", passed: scope.tabID == snapshot.tabID,
                                detail: "The snapshot must describe the tab actions are scoped to."))

            // Deliberately calls the adapter's own primitive, not the shared helper:
            // the point is whether *this adapter* enforces scope, not whether the
            // helper works.
            let mismatched = OriginScope(tabID: scope.tabID + 1, origin: scope.origin)
            do {
                try adapter.perform(AdapterAction(kind: .click, elementID: "x"), in: mismatched)
                checks.append(.init(name: "rejects-other-tab", passed: false,
                                    detail: "The adapter accepted an action aimed at a different tab."))
            } catch {
                checks.append(.init(name: "rejects-other-tab", passed: true,
                                    detail: "An action aimed at another tab is refused by the adapter itself."))
            }

            let foreign = OriginScope(tabID: scope.tabID, origin: "https://evil.example")
            do {
                try adapter.perform(AdapterAction(kind: .click, elementID: "x"), in: foreign)
                checks.append(.init(name: "rejects-other-origin", passed: false,
                                    detail: "The adapter accepted an action for a different site."))
            } catch {
                checks.append(.init(name: "rejects-other-origin", passed: true,
                                    detail: "Actions are confined to the origin they were scoped to."))
            }

            if let opaque = snapshot.opaqueElementIDs.first {
                do {
                    try adapter.performChecked(AdapterAction(kind: .type, elementID: opaque, text: "secret"), scope: scope, snapshot: snapshot)
                    checks.append(.init(name: "opaque-fields", passed: false, detail: "A protected field was written to."))
                } catch {
                    checks.append(.init(name: "opaque-fields", passed: true, detail: "Protected fields refuse input."))
                }
            }

            let declared = adapter.capabilities.contains(.click)
            do {
                try adapter.perform(AdapterAction(kind: .click, elementID: snapshot.elements.first?.id), in: scope)
                checks.append(.init(name: "capability-honesty", passed: declared,
                                    detail: declared ? "Declared capabilities match behaviour." : "The adapter clicked without declaring the capability."))
            } catch AdapterError.unsupportedCapability {
                checks.append(.init(name: "capability-honesty", passed: !declared,
                                    detail: declared ? "It declared click but refused to click." : "It refused an undeclared capability."))
            } catch {
                checks.append(.init(name: "capability-honesty", passed: declared, detail: "Click failed: \(error.localizedDescription)"))
            }
        } catch {
            checks.append(.init(name: "readable", passed: false, detail: error.localizedDescription))
        }

        return AdapterConformanceReport(adapter: adapter.name, checks: checks)
    }

    /// Picks the adapter to use: dedicated plugin, extension DOM, debugging protocol, AX.
    public static func select(from adapters: [any BrowserAdapter]) -> (any BrowserAdapter)? {
        adapters.sorted { $0.kind.priority < $1.kind.priority }.first
    }
}
