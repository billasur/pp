import Foundation

/// Protocol abstracting decision providers (MLX Laya, HTTP dev oracle, StubProvider, RecordedProvider).
public protocol DecisionProvider: Sendable {
    var requiresAPIKey: Bool { get }
    func decide(context: CommandContext, candidates: [Candidate], apiKey: String?) async throws -> Decision
    func cycle(state: JevClient.CycleState, operations: [String: String], heads: [String: [String: String]], apiKey: String?) async throws -> Decision
    func ground(context: JevClient.GroundingContext, candidates: [Candidate], apiKey: String?) async throws -> Decision
    func warmUp()
}
