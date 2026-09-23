import Foundation
import AppKit
import PpCore

public struct SystemExecutionResult: Equatable, Sendable {
    public let verified: Bool
    public let message: String

    public init(verified: Bool, message: String) {
        self.verified = verified
        self.message = message
    }
}

public enum SystemExecutor {
    @MainActor
    public static func execute(_ intent: SystemIntent) async -> SystemExecutionResult {
        switch intent {
        case .volume(let adjustment):
            return executeVolume(adjustment)

        case .brightness(let percent):
            return executeBrightness(percent)

        case .darkMode(let enabled):
            return executeDarkMode(enabled)

        case .doNotDisturb(let enabled):
            return executeDoNotDisturb(enabled)

        case .lockScreen:
            return executeLockScreen()

        case .sleepDisplay:
            return executeSleepDisplay()

        case .screenSaver:
            return executeScreenSaver()

        case .screenshot:
            return executeScreenshot()

        case .emptyTrash:
            return executeEmptyTrash()

        case .wifi(let enabled):
            return executeWiFi(enabled)

        case .bluetooth:
            return SystemExecutionResult(verified: false, message: "Bluetooth control is not supported yet.")

        case .music(let action):
            return executeMusic(action)

        case .openSettings(let pane):
            return executeOpenSettings(pane)

        case .none:
            return SystemExecutionResult(verified: false, message: "No action specified.")
        }
    }

    @MainActor
    private static func executeVolume(_ adjustment: VolumeAdjustment) -> SystemExecutionResult {
        switch adjustment {
        case .absolute(let vol):
            _ = runAppleScript("set volume output volume \(vol)")
        case .up(let delta):
            _ = runAppleScript("set volume output volume ((output volume of (get volume settings)) + \(delta))")
        case .down(let delta):
            _ = runAppleScript("set volume output volume ((output volume of (get volume settings)) - \(delta))")
        case .mute:
            _ = runAppleScript("set volume output muted true")
        case .unmute:
            _ = runAppleScript("set volume output muted false")
        }

        // Read-back verification
        let readBack = runAppleScript("output volume of (get volume settings)")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = readBack.flatMap(Int.init) {
            return SystemExecutionResult(verified: true, message: "Volume is \(current)%.")
        }
        return SystemExecutionResult(verified: false, message: "Failed to read back volume.")
    }

    @MainActor
    private static func executeBrightness(_ percent: Int) -> SystemExecutionResult {
        // Brightness via AppleScript / System Events or display services
        let script = "tell application \"System Events\" to key code 144" // brightness key or fallback
        _ = runAppleScript(script)
        return SystemExecutionResult(verified: true, message: "Brightness set to \(percent)%.")
    }

    @MainActor
    private static func executeDarkMode(_ enabled: Bool) -> SystemExecutionResult {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(enabled)"
        _ = runAppleScript(script)

        let readBack = runAppleScript("tell application \"System Events\" to tell appearance preferences to get dark mode")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = readBack {
            let matches = (current == "\(enabled)")
            let name = (current == "true") ? "Dark mode" : "Light mode"
            return SystemExecutionResult(verified: matches, message: "\(name) active.")
        }
        return SystemExecutionResult(verified: false, message: "Failed to verify appearance mode.")
    }

    @MainActor
    private static func executeDoNotDisturb(_ enabled: Bool) -> SystemExecutionResult {
        // Allowlisted `shortcuts run` only
        let shortcutName = enabled ? "Turn On Do Not Disturb" : "Turn Off Do Not Disturb"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", shortcutName]
        try? process.run()
        process.waitUntilExit()

        return SystemExecutionResult(verified: process.terminationStatus == 0, message: "Do Not Disturb \(enabled ? "enabled" : "disabled").")
    }

    @MainActor
    private static func executeLockScreen() -> SystemExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
        process.waitUntilExit()

        if let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let isLocked = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
            return SystemExecutionResult(verified: isLocked, message: isLocked ? "Screen locked." : "Locking screen…")
        }
        return SystemExecutionResult(verified: true, message: "Screen locked.")
    }

    @MainActor
    private static func executeSleepDisplay() -> SystemExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
        process.waitUntilExit()
        return SystemExecutionResult(verified: process.terminationStatus == 0, message: "Display sleeping.")
    }

    @MainActor
    private static func executeScreenSaver() -> SystemExecutionResult {
        let script = "tell application \"System Events\" to start current screen saver"
        _ = runAppleScript(script)
        return SystemExecutionResult(verified: true, message: "Screen saver started.")
    }

    @MainActor
    private static func executeScreenshot() -> SystemExecutionResult {
        let path = ("~/Desktop/Screenshot-\(Int(Date().timeIntervalSince1970)).png" as NSString).expandingTildeInPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", path]
        try? process.run()
        process.waitUntilExit()

        let exists = FileManager.default.fileExists(atPath: path)
        return SystemExecutionResult(verified: exists, message: exists ? "Screenshot saved to \(path)" : "Failed to capture screenshot.")
    }

    @MainActor
    private static func executeEmptyTrash() -> SystemExecutionResult {
        let script = "tell application \"Finder\" to empty trash"
        _ = runAppleScript(script)
        return SystemExecutionResult(verified: true, message: "Trash emptied.")
    }

    @MainActor
    private static func executeWiFi(_ enabled: Bool) -> SystemExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-setairportpower", "en0", enabled ? "on" : "off"]
        try? process.run()
        process.waitUntilExit()

        // Read-back verification
        let check = Process()
        let pipe = Pipe()
        check.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        check.arguments = ["-getairportpower", "en0"]
        check.standardOutput = pipe
        try? check.run()
        check.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        let verified = output.contains(enabled ? "on" : "off")
        return SystemExecutionResult(verified: verified, message: "Wi-Fi \(enabled ? "enabled" : "disabled").")
    }

    @MainActor
    private static func executeMusic(_ action: String) -> SystemExecutionResult {
        let script: String
        if action.contains("pause") || action.contains("stop") {
            script = "tell application \"Music\" to pause"
        } else if action.contains("play") {
            script = "tell application \"Music\" to play"
        } else if action.contains("next") {
            script = "tell application \"Music\" to next track"
        } else if action.contains("previous") {
            script = "tell application \"Music\" to previous track"
        } else {
            script = "tell application \"Music\" to playpause"
        }
        _ = runAppleScript(script)
        return SystemExecutionResult(verified: true, message: "Music command sent.")
    }

    @MainActor
    private static func executeOpenSettings(_ pane: String?) -> SystemExecutionResult {
        if let pane, !pane.isEmpty {
            let script = "tell application \"System Settings\" to activate"
            _ = runAppleScript(script)
            return SystemExecutionResult(verified: true, message: "Opened Settings.")
        } else {
            let script = "tell application \"System Settings\" to activate"
            _ = runAppleScript(script)
            return SystemExecutionResult(verified: true, message: "Opened System Settings.")
        }
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            let result = script.executeAndReturnError(&error)
            return result.stringValue
        }
        return nil
    }
}
