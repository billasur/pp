import XCTest
@testable import PpCore

final class NoCloudTests: XCTestCase {
    func testKeyStoreDefaultsToLocalDecisionKey() {
        XCTAssertEqual(KeyStore.decision, "decision-api-key")
        XCTAssertFalse(KeyStore.decision.contains("typesafe"))
        XCTAssertFalse(KeyStore.decision.contains("openrouter"))
    }

    #if !ENABLE_CLOUD_PLANNER
    func testNoCloudPlannerKeyExposedInShippingBuild() {
        // Assert that KeyStore.decision is the standard account
        XCTAssertEqual(KeyStore.decision, "decision-api-key")
        // Verify Planner endpoint defaults to local address
        XCTAssertEqual(Planner.endpoint.host, "127.0.0.1")
    }
    #endif

    func testStubProviderRequiresNoCloudCredentials() async throws {
        let stub = StubProvider(mode: .safeNoOp)
        XCTAssertFalse(stub.requiresAPIKey)

        // 1. decide safe no-op
        let context = CommandContext(command: "Test", application: "Finder", window: "Home")
        let candidate = Candidate(id: "done", label: "Done", detail: "Done")
        let decideOutcome = try await stub.decide(context: context, candidates: [candidate], apiKey: nil)
        XCTAssertEqual(decideOutcome.answers["action"]?.choice, "done")

        // 2. cycle safe no-op
        let state = JevClient.CycleState(goal: "Test", dictation: nil, application: "Finder", window: "Home",
                                         elements: [], available: JevClient.Available(apps: [], folders: [], sites: [], menus: []),
                                         recentActions: [], previous: nil)
        let cycleOutcome = try await stub.cycle(state: state, operations: ["DONE": "done"], heads: [:], apiKey: nil)
        XCTAssertEqual(cycleOutcome.answers["operation"]?.choice, "DONE")
        XCTAssertEqual(cycleOutcome.answers["finishes"]?.noul, 1.0)

        // 3. ground safe no-op
        let step = PlanStep(kind: .click, target: "Button", ordinal: 1)
        let groundContext = JevClient.GroundingContext(step: step, goal: "Click Button", application: "Finder", window: "Home")
        let groundOutcome = try await stub.ground(context: groundContext, candidates: [candidate], apiKey: nil)
        XCTAssertEqual(groundOutcome.answers["target"]?.choice, "none")
        XCTAssertEqual(groundOutcome.answers["already_done"]?.noul, 1.0)
    }

    func testStubProviderEmptyAnswersMode() async throws {
        let stub = StubProvider(mode: .emptyAnswers)
        let context = CommandContext(command: "Test", application: "Finder", window: "Home")
        let outcome = try await stub.decide(context: context, candidates: [], apiKey: nil)
        XCTAssertTrue(outcome.answers.isEmpty)
    }
}
