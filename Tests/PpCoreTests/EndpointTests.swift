import XCTest
@testable import PpCore

private final class EndpointTestURLProtocol: URLProtocol {
    static var lastRequest: URLRequest?
    static var responseData: Data = Data(#"{"answers":{"operation":{"type":"choice","choice":"DONE","confidence":1.0,"probabilities":{"DONE":1.0}},"target":{"type":"choice","choice":"none","confidence":1.0,"probabilities":{"none":1.0}},"action":{"type":"choice","choice":"done","confidence":1.0,"probabilities":{"done":1.0}},"more":{"type":"noul","noul":0.0}}}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        EndpointTestURLProtocol.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: EndpointTestURLProtocol.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class EndpointTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: DecisionEndpoint.userDefaultsKey)
        EndpointTestURLProtocol.lastRequest = nil
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DecisionEndpoint.userDefaultsKey)
        super.tearDown()
    }

    func testDecisionEndpointDefaultsToDevStub() {
        XCTAssertEqual(DecisionEndpoint.currentURL, URL(string: "http://127.0.0.1:8000/v1/systemone")!)
        XCTAssertFalse(DecisionEndpoint.currentURL.absoluteString.contains("typesafe"))
    }

    func testDecisionEndpointReadsFromUserDefaults() {
        let custom = "http://127.0.0.1:9090/v1/custom"
        UserDefaults.standard.set(custom, forKey: DecisionEndpoint.userDefaultsKey)
        XCTAssertEqual(DecisionEndpoint.currentURL, URL(string: custom)!)
    }

    func testAllFourCallSitesResolveToInjectedEndpoint() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EndpointTestURLProtocol.self]
        let testSession = URLSession(configuration: config)

        let targetEndpoint = URL(string: "http://127.0.0.1:7777/injected/endpoint")!
        let provider = HTTPProvider(endpoint: targetEndpoint, session: testSession)

        // 1. warmUp
        provider.warmUp()
        // Wait briefly for dataTask to hit URLProtocol
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(EndpointTestURLProtocol.lastRequest?.url, targetEndpoint)
        XCTAssertEqual(EndpointTestURLProtocol.lastRequest?.httpMethod, "HEAD")

        // 2. decide
        let context = CommandContext(command: "Open App", application: "Finder", window: "Home")
        let candidate = Candidate(id: "c1", label: "App", detail: "Open App")
        _ = try await provider.decide(context: context, candidates: [candidate], apiKey: "test-key")
        XCTAssertEqual(EndpointTestURLProtocol.lastRequest?.url, targetEndpoint)
        XCTAssertEqual(EndpointTestURLProtocol.lastRequest?.httpMethod, "POST")

        // 3. cycle
        let state = JevClient.CycleState(goal: "Test", dictation: nil, application: "Finder", window: "Home",
                                         elements: [], available: JevClient.Available(apps: [], folders: [], sites: [], menus: []),
                                         recentActions: [], previous: nil)
        _ = try await provider.cycle(state: state, operations: ["DONE": "done"], heads: [:], apiKey: "test-key")
        XCTAssertEqual(EndpointTestURLProtocol.lastRequest?.url, targetEndpoint)
        XCTAssertEqual(EndpointTestURLProtocol.lastRequest?.httpMethod, "POST")

        // 4. ground
        let step = PlanStep(kind: .click, target: "Button", ordinal: 1)
        let groundContext = JevClient.GroundingContext(step: step, goal: "Click Button", application: "Finder", window: "Home")
        _ = try await provider.ground(context: groundContext, candidates: [candidate], apiKey: "test-key")
        XCTAssertEqual(EndpointTestURLProtocol.lastRequest?.url, targetEndpoint)
        XCTAssertEqual(EndpointTestURLProtocol.lastRequest?.httpMethod, "POST")
    }

    func testErrorMessageContainsNoTypesafeLiteral() {
        let error = DecisionServiceError(status: 401, message: "Unauthorized")
        XCTAssertFalse(error.localizedDescription.lowercased().contains("typesafe"))
    }
}
