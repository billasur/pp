import Foundation

public enum VolumeAdjustment: Equatable, Sendable {
    case absolute(Int)
    case up(Int)
    case down(Int)
    case mute
    case unmute
}

public enum SystemIntent: Equatable, Sendable {
    case volume(VolumeAdjustment)
    case brightness(percent: Int)
    case darkMode(enabled: Bool)
    case doNotDisturb(enabled: Bool)
    case lockScreen
    case sleepDisplay
    case screenSaver
    case screenshot
    case emptyTrash
    case wifi(enabled: Bool)
    case bluetooth(enabled: Bool)
    case music(action: String)
    case openSettings(pane: String?)
    case none

    public var isActionable: Bool {
        self != .none
    }
}

public enum SystemIntentParser {
    public static func parse(_ utterance: String) -> SystemIntent {
        let clean = utterance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Volume
        if let vol = parseVolume(clean) { return .volume(vol) }

        // 2. Brightness
        if let bright = parseBrightness(clean) { return .brightness(percent: bright) }

        // 3. Dark mode
        if clean == "turn on dark mode" || clean == "enable dark mode" || clean == "dark mode on" || clean == "dark mode" {
            return .darkMode(enabled: true)
        }
        if clean == "turn off dark mode" || clean == "disable dark mode" || clean == "dark mode off" || clean == "light mode" || clean == "turn on light mode" {
            return .darkMode(enabled: false)
        }

        // 4. Do Not Disturb
        if clean == "turn on do not disturb" || clean == "enable do not disturb" || clean == "do not disturb on" || clean == "dnd on" {
            return .doNotDisturb(enabled: true)
        }
        if clean == "turn off do not disturb" || clean == "disable do not disturb" || clean == "do not disturb off" || clean == "dnd off" {
            return .doNotDisturb(enabled: false)
        }

        // 5. Lock screen
        if clean == "lock screen" || clean == "lock the screen" || clean == "lock mac" || clean == "lock my mac" || clean == "lock my screen" || clean == "lock computer" {
            return .lockScreen
        }

        // 6. Sleep display
        if clean == "sleep display" || clean == "turn off display" || clean == "sleep screen" {
            return .sleepDisplay
        }

        // 7. Screen saver
        if clean == "start screensaver" || clean == "start screen saver" || clean == "screensaver" || clean == "screen saver" {
            return .screenSaver
        }

        // 8. Screenshot
        if clean == "take screenshot" || clean == "take a screenshot" || clean == "screenshot" || clean == "capture screen" {
            return .screenshot
        }

        // 9. Empty trash
        if clean == "empty trash" || clean == "empty the trash" || clean == "empty bin" {
            return .emptyTrash
        }

        // 10. Wi-Fi
        if clean == "turn on wifi" || clean == "turn on wi-fi" || clean == "enable wifi" || clean == "wifi on" {
            return .wifi(enabled: true)
        }
        if clean == "turn off wifi" || clean == "turn off wi-fi" || clean == "disable wifi" || clean == "wifi off" {
            return .wifi(enabled: false)
        }

        // 11. Bluetooth
        if clean == "turn on bluetooth" || clean == "enable bluetooth" || clean == "bluetooth on" {
            return .bluetooth(enabled: true)
        }
        if clean == "turn off bluetooth" || clean == "disable bluetooth" || clean == "bluetooth off" {
            return .bluetooth(enabled: false)
        }

        // 12. Music
        if clean == "pause music" || clean == "stop music" || clean == "play music" || clean == "next song" || clean == "previous song" {
            return .music(action: clean)
        }

        // 13. Open settings
        if clean == "open settings" || clean == "open system settings" || clean == "system preferences" {
            return .openSettings(pane: nil)
        }
        if clean.hasPrefix("open settings ") || clean.hasPrefix("open ") && clean.hasSuffix(" settings") {
            let pane = clean.replacingOccurrences(of: "open settings ", with: "")
                .replacingOccurrences(of: "open ", with: "")
                .replacingOccurrences(of: " settings", with: "")
                .trimmingCharacters(in: .whitespaces)
            return .openSettings(pane: pane)
        }

        return .none
    }

    private static func parseVolume(_ clean: String) -> VolumeAdjustment? {
        if clean == "mute" || clean == "mute volume" || clean == "volume mute" {
            return .mute
        }
        if clean == "unmute" || clean == "unmute volume" {
            return .unmute
        }

        if clean == "turn up the volume" || clean == "turn up volume" || clean == "volume up" || clean == "increase volume" {
            return .up(10)
        }
        if clean == "turn down the volume" || clean == "turn down volume" || clean == "volume down" || clean == "decrease volume" || clean == "lower volume" {
            return .down(10)
        }

        let upPrefixes = ["volume up by ", "increase volume by ", "turn up volume by "]
        for p in upPrefixes {
            if clean.hasPrefix(p) {
                let rest = String(clean.dropFirst(p.count))
                if let amount = NumberWords.parsePercentage(rest) {
                    return .up(amount)
                }
            }
        }

        let downPrefixes = ["volume down by ", "decrease volume by ", "turn down volume by "]
        for p in downPrefixes {
            if clean.hasPrefix(p) {
                let rest = String(clean.dropFirst(p.count))
                if let amount = NumberWords.parsePercentage(rest) {
                    return .down(amount)
                }
            }
        }

        let setPrefixes = ["set volume to ", "volume to ", "volume "]
        for p in setPrefixes {
            if clean.hasPrefix(p) {
                let rest = String(clean.dropFirst(p.count))
                if let vol = NumberWords.parsePercentage(rest), vol >= 0 && vol <= 100 {
                    return .absolute(vol)
                }
            }
        }

        return nil
    }

    private static func parseBrightness(_ clean: String) -> Int? {
        let setPrefixes = ["set brightness to ", "brightness to ", "brightness "]
        for p in setPrefixes {
            if clean.hasPrefix(p) {
                let rest = String(clean.dropFirst(p.count))
                if let pct = NumberWords.parsePercentage(rest), pct >= 0 && pct <= 100 {
                    return pct
                }
            }
        }
        return nil
    }
}
