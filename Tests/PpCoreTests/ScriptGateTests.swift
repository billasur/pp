import XCTest
@testable import PpCore

final class ScriptGateTests: XCTestCase {
    func testLegitimateWindowSnapScriptPassesGates() {
        let script = """
        tell application "Finder"
            set bounds of front window to {0, 0, 800, 600}
        end tell
        """
        let compileRes = ScriptGates.checkCompile(source: script)
        guard case .success = compileRes else { return XCTFail("Expected compile success") }

        let effectRes = ScriptGates.checkEffect(source: script)
        guard case .success = effectRes else { return XCTFail("Expected effect success") }

        let policyRes = ScriptGates.checkPolicy(source: script)
        guard case .success = policyRes else { return XCTFail("Expected policy success") }

        let allRes = ScriptGates.evaluateAll(source: script, probability: 0.8)
        guard case .success = allRes else { return XCTFail("Expected evaluateAll success") }
    }

    func testEmptyStubFailsEffectGate() {
        let script = """
        tell application "Finder"
            return
        end tell
        """
        let effectRes = ScriptGates.checkEffect(source: script)
        guard case .failure(let err) = effectRes else {
            return XCTFail("Expected failure for empty script")
        }
        XCTAssertTrue(err.errorDescription?.contains("no measurable effect") == true)
    }

    func testSshAccessFailsPolicyGate() {
        let script = """
        set key to do shell script "cat ~/.ssh/id_rsa"
        """
        let policyRes = ScriptGates.checkPolicy(source: script)
        guard case .failure(let err) = policyRes else {
            return XCTFail("Expected failure for ~/.ssh access")
        }
        XCTAssertTrue(err.errorDescription?.contains("protected target") == true)
    }

    func testTerminalAccessFailsPolicyGate() {
        let script = """
        tell application "Terminal"
            do script "echo hello"
        end tell
        """
        let policyRes = ScriptGates.checkPolicy(source: script)
        guard case .failure(let err) = policyRes else {
            return XCTFail("Expected failure for Terminal script")
        }
        XCTAssertTrue(err.errorDescription?.contains("protected target") == true)
    }

    func testDangerousShellRmFailsPolicyGate() {
        let script = """
        do shell script "rm -rf ~/Downloads"
        """
        let policyRes = ScriptGates.checkPolicy(source: script)
        guard case .failure(let err) = policyRes else {
            return XCTFail("Expected failure for rm -rf")
        }
        XCTAssertTrue(err.errorDescription?.contains("dangerous utility") == true)
    }

    func testLowProbabilityFailsVerificationGate() {
        let script = """
        tell application "System Events"
            keystroke "a"
        end tell
        """
        let verifRes = ScriptGates.checkVerification(probability: 0.2, threshold: 0.4)
        guard case .failure(let err) = verifRes else {
            return XCTFail("Expected failure for low verification probability")
        }
        XCTAssertTrue(err.errorDescription?.contains("P(script achieves goal)") == true)
    }
}
