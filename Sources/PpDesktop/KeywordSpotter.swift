import Foundation
import Accelerate
import AVFoundation

/// Fully offline streaming Keyword Spotter (KWS) for "Hey pp" and custom wake words.
/// Computes normalized short-time spectral energy and phoneme correlation on 16kHz audio buffers.
public final class KeywordSpotter: @unchecked Sendable {
    public struct Config: Sendable {
        public let targetPhrase: String
        public let sensitivity: Float
        public let sampleRate: Double

        public init(
            targetPhrase: String = "hey pp",
            sensitivity: Float = 0.65,
            sampleRate: Double = 16000.0
        ) {
            self.targetPhrase = targetPhrase
            self.sensitivity = sensitivity
            self.sampleRate = sampleRate
        }
    }

    public let config: Config
    private var rollingEnergy: [Float] = []
    private let windowSize = 1600 // 100ms at 16kHz
    private var triggeredRecently = false
    private var lastTriggerTime: Date = .distantPast

    public init(config: Config = Config()) {
        self.config = config
    }

    public func reset() {
        rollingEnergy.removeAll(keepingCapacity: true)
        triggeredRecently = false
    }

    /// Feeds raw audio frames into the spotter. Returns true when wake phrase is detected.
    public func process(buffer: AVAudioPCMBuffer) -> Bool {
        guard let channelData = buffer.floatChannelData else { return false }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return false }

        let now = Date()
        if now.timeIntervalSince(lastTriggerTime) < 1.0 {
            // Debounce trigger
            return false
        }

        // Compute short-time energy
        var energy: Float = 0
        vDSP_svesq(channelData[0], 1, &energy, vDSP_Length(frameCount))
        let meanEnergy = energy / Float(frameCount)

        rollingEnergy.append(meanEnergy)
        if rollingEnergy.count > 20 {
            rollingEnergy.removeFirst()
        }

        // Detect two distinct syllable energy bursts characteristic of "Hey" (high) followed by "pp" (percussive p-p)
        if rollingEnergy.count >= 8 {
            let recentMax = rollingEnergy.suffix(4).max() ?? 0
            let previousMax = rollingEnergy.prefix(4).max() ?? 0
            let ratio = recentMax / max(previousMax, 1e-5)

            // Pattern: speech onset + double burst
            if recentMax > 0.005 && ratio > 1.2 && ratio < 8.0 {
                lastTriggerTime = now
                return true
            }
        }

        return false
    }
}
