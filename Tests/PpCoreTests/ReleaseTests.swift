import XCTest
@testable import PpCore

// MARK: Onboarding

private struct FakeProbe: PermissionProbing {
    var statuses: [PermissionKind: PermissionStatus]
    func status(of kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .notDetermined }
    func request(_ kind: PermissionKind) {}
}

final class OnboardingTests: XCTestCase {

    func testNamesTheFirstMissingPermission() {
        let probe = FakeProbe(statuses: [.accessibility: .granted, .microphone: .denied, .speechRecognition: .granted])
        let coordinator = OnboardingCoordinator(probe: probe, modelReady: { true })
        XCTAssertEqual(coordinator.currentStep(), .needsPermission(.microphone))
        XCTAssertFalse(coordinator.permissionsSatisfied)
    }

    func testAsksForTheModelOncePermissionsAreGranted() {
        let probe = FakeProbe(statuses: [:])
        let coordinator = OnboardingCoordinator(probe: probe, modelReady: { false })
        XCTAssertEqual(coordinator.currentStep(), .needsPermission(.accessibility))

        let allGranted = FakeProbe(statuses: Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .granted) }))
        let ready = OnboardingCoordinator(probe: allGranted, modelReady: { false })
        XCTAssertEqual(ready.currentStep(), .needsModel)
        XCTAssertTrue(ready.permissionsSatisfied)

        let complete = OnboardingCoordinator(probe: allGranted, modelReady: { true })
        XCTAssertEqual(complete.currentStep(), .ready)
    }

    func testEachPermissionDeepLinksToItsOwnSettingsPane() {
        let urls = PermissionKind.allCases.map { $0.settingsURL.absoluteString }
        XCTAssertEqual(Set(urls).count, PermissionKind.allCases.count, "every permission needs its own pane")
        for url in urls {
            XCTAssertTrue(url.hasPrefix("x-apple.systempreferences:"), "\(url) should open System Settings directly")
        }
        XCTAssertTrue(PermissionKind.accessibility.settingsURL.absoluteString.contains("Privacy_Accessibility"))
    }

    func testEveryPermissionIsExplained() {
        for kind in PermissionKind.allCases {
            XCTAssertFalse(kind.explanation.isEmpty)
            XCTAssertTrue(kind.explanation.lowercased().contains("pp"), "the explanation should say what pp does")
        }
    }
}

// MARK: Update channels

final class UpdateChannelTests: XCTestCase {

    private func appUpdate(weights: Bool = false, executable: Bool = true) -> UpdateManifest {
        UpdateManifest(channel: .app, version: "0.2.0", url: URL(string: "https://example.com/pp.zip")!,
                       sha256: String(repeating: "a", count: 64), minAppVersion: nil,
                       containsModelWeights: weights, containsExecutable: executable)
    }

    private func modelUpdate(executable: Bool = false, weights: Bool = true) -> UpdateManifest {
        UpdateManifest(channel: .models, version: "2.0.0", url: URL(string: "https://example.com/model.tar.gz")!,
                       sha256: String(repeating: "b", count: 64), minAppVersion: nil,
                       containsModelWeights: weights, containsExecutable: executable)
    }

    func testAppUpdatesNeverCarryWeights() {
        XCTAssertThrowsError(try UpdatePolicy.validate(appUpdate(weights: true), currentAppVersion: "0.1.0")) { error in
            XCTAssertEqual(error as? UpdateError, .appUpdateCarriesWeights)
        }
        XCTAssertNoThrow(try UpdatePolicy.validate(appUpdate(), currentAppVersion: "0.1.0"))
        XCTAssertTrue(UpdatePolicy.leavesModelsUntouched(appUpdate()))
        XCTAssertFalse(UpdatePolicy.leavesModelsUntouched(modelUpdate()))
    }

    func testModelPackagesNeverCarryExecutables() {
        XCTAssertThrowsError(try UpdatePolicy.validate(modelUpdate(executable: true), currentAppVersion: "0.1.0")) { error in
            XCTAssertEqual(error as? UpdateError, .modelUpdateCarriesExecutable)
        }
        XCTAssertNoThrow(try UpdatePolicy.validate(modelUpdate(), currentAppVersion: "0.1.0"))
    }

    func testAnAppUpdateWithNoExecutableIsRefusedAsUnsigned() {
        XCTAssertThrowsError(try UpdatePolicy.validate(appUpdate(executable: false), currentAppVersion: "0.1.0")) { error in
            XCTAssertEqual(error as? UpdateError, .unsigned)
        }
    }

    func testMinimumAppVersionIsEnforced() {
        var manifest = appUpdate()
        manifest = UpdateManifest(channel: .app, version: manifest.version, url: manifest.url, sha256: manifest.sha256,
                                  minAppVersion: "9.0.0", containsModelWeights: false, containsExecutable: true)
        XCTAssertThrowsError(try UpdatePolicy.validate(manifest, currentAppVersion: "0.1.0")) { error in
            XCTAssertEqual(error as? UpdateError, .requiresNewerApp(required: "9.0.0", current: "0.1.0"))
        }
    }

    func testPayloadMustMatchItsChecksum() throws {
        let payload = Data("update".utf8)
        let manifest = UpdateManifest(channel: .app, version: "0.2.0", url: URL(string: "https://example.com/a")!,
                                      sha256: UpdateVerifier.sha256(of: payload), containsModelWeights: false,
                                      containsExecutable: true)
        XCTAssertNoThrow(try UpdateVerifier.verify(payload: payload, against: manifest))

        let tampered = UpdateManifest(channel: .app, version: "0.2.0", url: manifest.url,
                                      sha256: String(repeating: "0", count: 64), containsModelWeights: false,
                                      containsExecutable: true)
        XCTAssertThrowsError(try UpdateVerifier.verify(payload: payload, against: tampered)) { error in
            XCTAssertEqual(error as? UpdateError, .checksumMismatch)
        }
    }

    func testVersionComparisonHandlesShortAndLongForms() {
        XCTAssertEqual(PpVersion.compare("1.2", "1.2.0"), 0)
        XCTAssertEqual(PpVersion.compare("0.1.0", "0.2.0"), -1)
        XCTAssertEqual(PpVersion.compare("2.0", "1.9.9"), 1)
    }
}

// MARK: Adapters

private struct FakeBrowserAdapter: BrowserAdapter {
    let name: String
    var kind: AdapterKind
    var capabilities: Set<AdapterCapability>
    var scope: OriginScope
    var snapshotValue: AdapterSnapshot
    /// When true, the adapter accepts actions aimed at other tabs — a conformance failure.
    var acceptsOtherTabs = false
    /// A well-behaved adapter refuses an action scoped to a different site.
    var origin = "https://zen.example"
    var clickSucceeds = true

    func currentScope() throws -> OriginScope { scope }
    func snapshot() throws -> AdapterSnapshot { snapshotValue }

    func perform(_ action: AdapterAction, in scope: OriginScope) throws {
        if !acceptsOtherTabs, scope.tabID != self.scope.tabID { throw AdapterError.outOfScope }
        if !acceptsOtherTabs, scope.origin != origin { throw AdapterError.outOfScope }
        guard capabilities.contains(.click) || action.kind != .click else { throw AdapterError.unsupportedCapability("click") }
        if action.kind == .click, !clickSucceeds { throw AdapterError.notImplemented }
    }
}

final class BrowserAdapterTests: XCTestCase {

    private func adapter(kind: AdapterKind = .extensionDOM, acceptsOtherTabs: Bool = false) -> FakeBrowserAdapter {
        FakeBrowserAdapter(
            name: "zen-extension", kind: kind, capabilities: [.readTree, .click],
            scope: OriginScope(tabID: 7, origin: "https://zen.example"),
            snapshotValue: AdapterSnapshot(tabID: 7, url: URL(string: "https://zen.example/notes"),
                                           title: "Notes",
                                           elements: [UICandidate(id: "e1", label: "Open", detail: "", role: .button)],
                                           opaqueElementIDs: ["pw"]),
            acceptsOtherTabs: acceptsOtherTabs)
    }

    func testOriginScopeRequiresTheSameSchemeAndHost() {
        let scope = OriginScope(tabID: 1, origin: "https://zen.example")
        XCTAssertTrue(scope.allows(URL(string: "https://zen.example/notes")!))
        XCTAssertFalse(scope.allows(URL(string: "https://zen.example.evil.com/notes")!))
        XCTAssertFalse(scope.allows(URL(string: "https://other.example/")!))
        XCTAssertFalse(scope.allows(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(scope.allows(URL(string: "http://zen.example/")!))
    }

    func testConformingAdapterPassesTheSuite() {
        let report = AdapterConformanceSuite.run(adapter())
        XCTAssertTrue(report.passed, "failures: \(report.checks.filter { !$0.passed })")
    }

    func testAnAdapterThatReachesOtherTabsFailsTheSuite() {
        let report = AdapterConformanceSuite.run(adapter(acceptsOtherTabs: true))
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.checks.contains { $0.name == "rejects-other-tab" && !$0.passed })
    }

    func testOpaqueFieldsRefuseInput() throws {
        let subject = adapter()
        let snapshot = try subject.snapshot()
        XCTAssertThrowsError(try subject.performChecked(AdapterAction(kind: .type, elementID: "pw", text: "hunter2"),
                                                        scope: try subject.currentScope(), snapshot: snapshot)) { error in
            XCTAssertEqual(error as? AdapterError, .opaqueField)
        }
    }

    func testFallbackOrderPrefersPluginsThenExtensionsThenAX() {
        let adapters: [any BrowserAdapter] = [adapter(kind: .accessibility), adapter(kind: .plugin), adapter(kind: .extensionDOM)]
        XCTAssertEqual(AdapterConformanceSuite.select(from: adapters)?.kind, .plugin)
        XCTAssertEqual(AdapterConformanceSuite.select(from: [adapter(kind: .accessibility)])?.kind, .accessibility)
        XCTAssertNil(AdapterConformanceSuite.select(from: []))
    }
}

// MARK: Plugins

private struct EchoTransport: PluginTransport {
    let response: Data?
    let failure: String?
    init(response: Data? = nil, failure: String? = nil) { self.response = response; self.failure = failure }

    func send(_ data: Data) throws -> Data {
        if let failure { throw PluginError.transport(failure) }
        return response ?? Data()
    }
}

final class PluginHostTests: XCTestCase {

    private func manifest(capabilities: [String] = ["read_tree"], methods: [String: String] = ["tree": "read_tree"]) -> PluginManifest {
        PluginManifest(id: "com.example.notes", name: "Notes", version: "1.0.0",
                       capabilities: capabilities, methods: methods)
    }

    private func okResponse(for request: Data) throws -> Data {
        let decoded = try JSONDecoder().decode(PluginRequest.self, from: request)
        let response = PluginResponse(jsonrpc: "2.0", id: decoded.id, result: ["ok": "yes"], error: nil)
        return try JSONEncoder().encode(response)
    }

    func testManifestRequiresMethodsToDeclareRealCapabilities() {
        let registry = PluginRegistry()
        let bad = manifest(capabilities: ["read_tree"], methods: ["type": "type"])
        XCTAssertThrowsError(try registry.register(bad)) { error in
            guard let pluginError = error as? PluginError, case .malformedManifest = pluginError else {
                return XCTFail("expected a malformed manifest error, got \(error)")
            }
        }
        XCTAssertNoThrow(try registry.register(manifest()))
    }

    func testUnknownPluginAndUndeclaredMethodAreRefused() throws {
        let registry = PluginRegistry()
        try registry.register(manifest())
        let host = PluginHost(registry: registry, transport: EchoTransport(response: try okResponse(for: try JSONRPC.encode(PluginRequest(id: 1, method: "tree")))))
        XCTAssertThrowsError(try host.call(plugin: "missing", method: "tree")) { error in
            XCTAssertEqual(error as? PluginError, .unknownPlugin("missing"))
        }
        XCTAssertThrowsError(try host.call(plugin: "com.example.notes", method: "type")) { error in
            XCTAssertEqual(error as? PluginError, .methodNotDeclared("type"))
        }
    }

    func testHighRiskCapabilityNeedsExplicitApproval() throws {
        let registry = PluginRegistry()
        try registry.register(manifest(capabilities: ["read_tree", "read_clipboard"], methods: ["clip": "read_clipboard"]))
        let request = try JSONRPC.encode(PluginRequest(id: 1, method: "clip"))
        let host = PluginHost(registry: registry, transport: EchoTransport(response: try okResponse(for: request)))

        XCTAssertThrowsError(try host.call(plugin: "com.example.notes", method: "clip")) { error in
            XCTAssertEqual(error as? PluginError, .highRiskNeedsApproval("read_clipboard"))
        }

        host.approvalHandler = { _, capability in capability == "read_clipboard" }
        let response = try host.call(plugin: "com.example.notes", method: "clip")
        XCTAssertEqual(response.result?["ok"], "yes")
    }

    func testJSONRPCRoundTripsAndRejectsGarbage() throws {
        let request = PluginRequest(id: 42, method: "tree", params: ["depth": "2"])
        let encoded = try JSONRPC.encode(request)
        XCTAssertTrue(encoded.last == 0x0A, "messages are newline-framed")

        let response = PluginResponse(jsonrpc: "2.0", id: 42, result: ["a": "b"], error: nil)
        let decoded = try JSONRPC.decode(try JSONEncoder().encode(response))
        XCTAssertEqual(decoded.id, 42)
        XCTAssertEqual(decoded.result?["a"], "b")

        XCTAssertThrowsError(try JSONRPC.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? PluginError, .malformedMessage)
        }
    }

    func testTransportFailureIsReportedNotSwallowed() throws {
        let registry = PluginRegistry()
        try registry.register(manifest())
        let host = PluginHost(registry: registry, transport: EchoTransport(failure: "socket closed"))
        XCTAssertThrowsError(try host.call(plugin: "com.example.notes", method: "tree")) { error in
            guard let pluginError = error as? PluginError, case .transport(let reason) = pluginError else {
                return XCTFail("expected a transport error, got \(error)")
            }
            XCTAssertTrue(reason.contains("socket closed"), "the underlying reason should survive")
        }
    }

    func testGrantedCapabilitiesAreVisible() throws {
        let registry = PluginRegistry()
        try registry.register(manifest())
        let host = PluginHost(registry: registry, transport: EchoTransport())
        XCTAssertEqual(host.grantedCapabilities(plugin: "com.example.notes"), [.readTree])
    }
}
