import XCTest
@testable import PpMLX

final class PpMLXTests: XCTestCase {
    func testModernBertDefaultConfig() {
        let config = ModernBertConfig.layaDefault
        XCTAssertEqual(config.hiddenSize, 1024)
        XCTAssertEqual(config.numHiddenLayers, 28)
        XCTAssertEqual(config.numAttentionHeads, 16)
        XCTAssertEqual(config.vocabSize, 50368)
        XCTAssertEqual(config.headActivation, "relu")
    }
}
