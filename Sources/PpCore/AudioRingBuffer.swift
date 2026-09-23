import Foundation
import AVFoundation

/// Fixed-capacity PCM ring buffer storing recent audio buffers for seamless recognition restarts.
public final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacitySeconds: Double
    private var sampleRate: Double = 16000.0
    private var channelCount: AVAudioChannelCount = 1
    private var buffers: [AVAudioPCMBuffer] = []
    private var totalFrames: AVAudioFrameCount = 0

    public init(capacitySeconds: Double = 2.0) {
        self.capacitySeconds = capacitySeconds
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        self.sampleRate = buffer.format.sampleRate
        self.channelCount = buffer.format.channelCount

        // Copy buffer to retain memory safely
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength

        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                dst[ch].initialize(from: src[ch], count: Int(buffer.frameLength))
            }
        }

        buffers.append(copy)
        totalFrames += copy.frameLength

        let maxFrames = AVAudioFrameCount(sampleRate * capacitySeconds)
        while totalFrames > maxFrames && !buffers.isEmpty {
            let removed = buffers.removeFirst()
            totalFrames -= removed.frameLength
        }
    }

    public func snapshot() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return buffers
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffers.removeAll()
        totalFrames = 0
    }
}
