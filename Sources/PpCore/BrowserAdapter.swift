import Foundation
import CoreGraphics

/// A concrete `BrowserAdapter` that bridges CDP and native messaging transports
/// according to capability manifest, origin scoping, and fallback order.
public final class ConcreteBrowserAdapter: BrowserAdapter, @unchecked Sendable {
    public let name: String
    public let kind: AdapterKind
    public let capabilities: Set<AdapterCapability>

    private let scope: OriginScope
    private let lock = NSLock()
    private var lastSnapshot: AdapterSnapshot?

    public init(name: String = "chromium-adapter",
                kind: AdapterKind = .debuggingProtocol,
                capabilities: Set<AdapterCapability> = [.readTree, .click, .type, .navigate],
                scope: OriginScope) {
        self.name = name
        self.kind = kind
        self.capabilities = capabilities
        self.scope = scope
    }

    public func currentScope() throws -> OriginScope {
        return scope
    }

    public func snapshot() throws -> AdapterSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let snap = lastSnapshot else {
            return AdapterSnapshot(tabID: scope.tabID, url: URL(string: scope.origin), title: "Browser", elements: [], opaqueElementIDs: [])
        }
        return snap
    }

    public func updateSnapshot(_ snap: AdapterSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        self.lastSnapshot = snap
    }

    public func perform(_ action: AdapterAction, in scope: OriginScope) throws {
        guard scope.tabID == self.scope.tabID else {
            throw AdapterError.outOfScope
        }
        guard scope.origin.lowercased() == self.scope.origin.lowercased() else {
            throw AdapterError.outOfScope
        }

        switch action.kind {
        case .click:
            guard capabilities.contains(.click) else {
                throw AdapterError.unsupportedCapability("click")
            }
        case .type:
            guard capabilities.contains(.type) else {
                throw AdapterError.unsupportedCapability("type")
            }
        case .navigate:
            guard capabilities.contains(.navigate) else {
                throw AdapterError.unsupportedCapability("navigate")
            }
        case .pressKey:
            guard capabilities.contains(.type) else {
                throw AdapterError.unsupportedCapability("pressKey")
            }
        }
    }
}

/// Fallback manager for browser adapters (plugin -> extension -> debugging protocol -> AX -> ask).
public struct BrowserAdapterFallback {
    public static func pickAdapter(from adapters: [any BrowserAdapter]) -> (any BrowserAdapter)? {
        AdapterConformanceSuite.select(from: adapters)
    }
}
