import AVFoundation
import Accelerate
import Foundation


/// End-of-utterance signal produced while audio streams in.
public enum EndOfUtteranceEvent: Sendable, Equatable {
    case speechStarted
    case speechContinuing(dbfs: Float)
    case endOfUtterance(totalDuration: Double)
}

/// Closes a spoken clause. The shipping implementation is an energy gate; a neural
/// model can replace it behind this protocol without touching callers.
public protocol EndOfUtteranceDetecting: AnyObject, Sendable {
    func reset()
    func process(buffer: AVAudioPCMBuffer) -> EndOfUtteranceEvent?
}

/// Energy-threshold end-of-utterance detector used to close a spoken clause.
///
/// This is deliberately *not* a neural model. It is an RMS gate over 16 kHz buffers
/// that reports when the speaker has stopped for long enough to end a clause. Speech
/// recognition itself is provided by `SpeechInput` (Apple's on-device recogniser).
/// A neural end-of-utterance model (Parakeet EOU on the Neural Engine) can replace
/// this behind the same `EndOfUtteranceDetecting` interface without touching callers.
public final class EnergyEOU: EndOfUtteranceDetecting, @unchecked Sendable {
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
    public func process(buffer: AVAudioPCMBuffer) -> EndOfUtteranceEvent? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        totalFramesProcessed += Int64(frameCount)

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
        }

        guard isSpeaking, let last = lastAudibleTime else { return nil }
        let silenceDuration = now.timeIntervalSince(last)
        guard silenceDuration >= config.silenceDurationSeconds else { return nil }
        isSpeaking = false
        let totalDuration = speechStartTime.map { now.timeIntervalSince($0) } ?? 0
        return .endOfUtterance(totalDuration: totalDuration)
    }
}
