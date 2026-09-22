import Foundation
import Accelerate
import AVFoundation

/// Lightweight, 100% offline End-Of-Utterance (EOU) and Voice Activity Detector (VAD).
/// Designed for low-latency voice streaming on Apple Silicon without cloud dependencies.
public final class ParakeetEOU: @unchecked Sendable {
    public struct Config: Sendable {
        public let sampleRate: Double
        public let silenceThresholdDbfs: Float
        public let silenceDurationSeconds: Double
        public let speechLeadDurationSeconds: Double

        public init(
            sampleRate: Double = 16000.0,
            silenceThresholdDbfs: Float = -40.0,
            silenceDurationSeconds: Double = 0.45,
            speechLeadDurationSeconds: Double = 0.15
        ) {
            self.sampleRate = sampleRate
            self.silenceThresholdDbfs = silenceThresholdDbfs
            self.silenceDurationSeconds = silenceDurationSeconds
            self.speechLeadDurationSeconds = speechLeadDurationSeconds
        }
    }

    public enum Event: Sendable {
        case speechStarted
        case speechContinuing(dbfs: Float)
        case endOfUtterance(totalDuration: Double)
    }

    public let config: Config
    private var isSpeaking = false
    private var speechStartTime: Date?
    private var lastAudibleTime: Date?
    private var totalFramesProcessed: Int64 = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    public func reset() {
        isSpeaking = false
        speechStartTime = nil
        lastAudibleTime = nil
        totalFramesProcessed = 0
    }

    /// Process a float audio buffer, returning an event if state changed.
    public func process(buffer: AVAudioPCMBuffer) -> Event? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        totalFramesProcessed += Int64(frameCount)

        // Compute RMS dBFS across channels
        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameCount))
        let dbfs = 20.0 * log10(max(rms, 1e-6))

        let now = Date()
        let isAudible = dbfs > config.silenceThresholdDbfs

        if isAudible {
            lastAudibleTime = now
            if !isSpeaking {
                isSpeaking = true
                speechStartTime = now
                return .speechStarted
            }
            return .speechContinuing(dbfs: dbfs)
        } else {
            if isSpeaking, let last = lastAudibleTime {
                let silenceDuration = now.timeIntervalSince(last)
                if silenceDuration >= config.silenceDurationSeconds {
                    isSpeaking = false
                    let totalDuration = speechStartTime.map { now.timeIntervalSince($0) } ?? 0
                    return .endOfUtterance(totalDuration: totalDuration)
                }
            }
            return nil
        }
    }
}
