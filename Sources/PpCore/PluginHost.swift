import Foundation

/// What a plugin declares it needs.
public struct PluginManifest: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let capabilities: [String]
    /// Methods the plugin exposes, each mapped to the capability it needs.
    public let methods: [String: String]

    public init(id: String, name: String, version: String, capabilities: [String], methods: [String: String]) {
        self.id = id; self.name = name; self.version = version
        self.capabilities = capabilities; self.methods = methods
    }

    public var declaredCapabilities: Set<AdapterCapability> {
        Set(capabilities.map(AdapterCapability.init(rawValue:)))
    }
}

public enum PluginError: LocalizedError, Equatable {
    case unknownPlugin(String)
    case methodNotDeclared(String)
    case capabilityNotGranted(String)
    case highRiskNeedsApproval(String)
    case malformedManifest(String)
    case malformedMessage
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .unknownPlugin(let id): return "No plugin named \(id) is installed."
        case .methodNotDeclared(let method): return "The plugin does not declare the method \(method)."
        case .capabilityNotGranted(let capability): return "This plugin was not granted \(capability)."
        case .highRiskNeedsApproval(let capability): return "\(capability) can read content you did not ask pp to read, so it needs your confirmation."
        case .malformedManifest(let reason): return "The plugin manifest is invalid: \(reason)"
        case .malformedMessage: return "The plugin sent a message pp could not read."
        case .transport(let reason): return "The plugin host failed: \(reason)"
        }
    }
}

/// JSON-RPC 2.0 over a unix socket. Small, boring, and easy to validate.
public struct PluginRequest: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let method: String
    public let params: [String: String]

    public init(id: Int, method: String, params: [String: String] = [:]) {
        self.jsonrpc = "2.0"; self.id = id; self.method = method; self.params = params
    }
}

public struct PluginResponse: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable {
        public let code: Int
        public let message: String
        public init(code: Int, message: String) { self.code = code; self.message = message }
    }
    public let jsonrpc: String
    public let id: Int?
    public let result: [String: String]?
    public let error: Failure?
}

public enum JSONRPC {
    public static func encode(_ request: PluginRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)  // newline-delimited framing
        return data
    }

    public static func decode(_ data: Data) throws -> PluginResponse {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, let decoded = try? JSONDecoder().decode(PluginResponse.self, from: Data(text.utf8)) else {
            throw PluginError.malformedMessage
        }
        return decoded
    }
}

/// Sends bytes to a plugin. A unix socket in production; a scripted double in tests.
public protocol PluginTransport: Sendable {
    func send(_ data: Data) throws -> Data
}

/// Validates and registers plugins.
public final class PluginRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var manifests: [String: PluginManifest] = [:]

    public init() {}

    /// A manifest must name itself and map every method to a capability it declares.
    public func register(_ manifest: PluginManifest) throws {
        guard !manifest.id.isEmpty else { throw PluginError.malformedManifest("missing id") }
        guard !manifest.name.isEmpty else { throw PluginError.malformedManifest("missing name") }
        let declared = manifest.declaredCapabilities
        for (method, capability) in manifest.methods {
            guard declared.contains(AdapterCapability(rawValue: capability)) else {
                throw PluginError.malformedManifest("method \(method) needs \(capability), which the plugin does not declare")
            }
        }
        lock.lock(); defer { lock.unlock() }
        manifests[manifest.id] = manifest
    }

    public func manifest(for id: String) -> PluginManifest? {
        lock.lock(); defer { lock.unlock() }
        return manifests[id]
    }
}

/// Calls plugins, enforcing their declared capabilities.
public final class PluginHost: @unchecked Sendable {
    private let registry: PluginRegistry
    private let transport: any PluginTransport
    private var nextID = 1

    public init(registry: PluginRegistry, transport: any PluginTransport) {
        self.registry = registry
        self.transport = transport
    }

    /// Set by the UI: called for each high-risk capability before the call goes out.
    /// Returning false refuses the call.
    public var approvalHandler: (@Sendable (String, String) -> Bool)?

    /// A plugin can only reach a method it declared, and only if that method's
    /// capability is not high risk or the user approved it.
    @discardableResult
    public func call(plugin id: String, method: String, params: [String: String] = [:]) throws -> PluginResponse {
        guard let manifest = registry.manifest(for: id) else { throw PluginError.unknownPlugin(id) }
        guard let capabilityName = manifest.methods[method] else { throw PluginError.methodNotDeclared(method) }
        let capability = AdapterCapability(rawValue: capabilityName)
        guard manifest.declaredCapabilities.contains(capability) else {
            throw PluginError.capabilityNotGranted(capabilityName)
        }
        if AdapterCapability.highRisk.contains(capability) {
            guard approvalHandler?(id, capabilityName) == true else {
                throw PluginError.highRiskNeedsApproval(capabilityName)
            }
        }

        let request = PluginRequest(id: nextID, method: method, params: params)
        nextID += 1
        let payload = try JSONRPC.encode(request)
        let responseData: Data
        do {
            responseData = try transport.send(payload)
        } catch {
            throw PluginError.transport(error.localizedDescription)
        }
        return try JSONRPC.decode(responseData)
    }

    /// The capability set a plugin actually has, for the UI to display.
    public func grantedCapabilities(plugin id: String) -> Set<AdapterCapability> {
        registry.manifest(for: id)?.declaredCapabilities ?? []
    }
}
