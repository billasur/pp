import AVFoundation
import Accelerate
import Combine
import Foundation
import Speech
import os

@MainActor
final class SpeechInput: ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var status = ""
    @Published var audioLevel: Double = 0
    var onFinal: ((String) -> Void)?
    var onIdle: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private var handsFree = false
    private var silenceTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private let eouDetector = EnergyEOU()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var audioGate: OSAllocatedUnfairLock<Bool>?
    private var tapInstalled = false
    private var generation = UUID()
    private var isStarting = false
    private var releaseRequested = false
    private var pendingFinal: String?
    private var recognitionMode = ""

    var hasPermissions: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized &&
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func requestPermissions() async -> Bool {
        let current = generation
        var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        guard generation == current else { return false }
        guard microphone == .authorized else {
            status = "Microphone access is not allowed. Enable it in System Settings → Privacy & Security → Microphone."
            return false
        }

        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard generation == current else { return false }
        guard speech == .authorized else {
            status = "Speech Recognition access is not allowed. Enable it in System Settings → Privacy & Security → Speech Recognition."
            return false
        }
        return true
    }

    func start(handsFree: Bool = false, wakePhrase: String? = nil) async throws {
        cancel()
        self.handsFree = handsFree
        let current = generation
        isStarting = true
        transcript = ""
        status = "Preparing microphone…"
        let permitted = await requestPermissions()
        guard generation == current, !Task.isCancelled else {
            if generation == current { cancel() }
            throw CancellationError()
        }
        isStarting = false
        guard permitted else { throw SpeechInputError(message: status) }
        guard let recognizer, recognizer.isAvailable else {
            status = "Apple speech recognition is currently unavailable."
            throw SpeechInputError(message: status)
        }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            status = "No microphone is available. Connect a microphone and try again."
            throw SpeechInputError(message: status)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate.isFinite, format.sampleRate > 0 else {
            status = "The microphone has no usable audio format. Check the selected input in System Settings → Sound."
            throw SpeechInputError(message: status)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if let wakePhrase { request.contextualStrings = [wakePhrase] }
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            recognitionMode = "Apple Neural Engine (100% offline)"
        } else {
            recognitionMode = "Apple speech"
        }
        self.request = request
        let gate = OSAllocatedUnfairLock(initialState: true)
        audioGate = gate
        eouDetector.reset()
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            gate.withLock { acceptingAudio in
                if acceptingAudio { request.append(buffer) }
            }
            if let event = self?.eouDetector.process(buffer: buffer) {
                if case .endOfUtterance = event {
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current, self.isListening, self.handsFree else { return }
                        if !self.transcript.isEmpty {
                            self.finish()
                        }
                    }
                }
            }
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var loudest: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                var rms: Float = 0
                vDSP_rmsqv(channels[channel], vDSP_Stride(buffer.stride), &rms, vDSP_Length(buffer.frameLength))
                loudest = max(loudest, rms)
            }
            let level = Double(max(0, min(1, (20 * log10(max(loudest, 0.000_001)) + 55) / 55)))
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.isListening else { return }
                self.audioLevel = level
            }
        }
        tapInstalled = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript {
                        self.transcript = text
                        if self.handsFree, !text.isEmpty, !self.releaseRequested {
                            self.silenceTask?.cancel()
                            self.silenceTask = Task { [weak self] in
                                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                                guard let self, self.generation == current else { return }
                                self.finish()
                            }
                        }
                    }
                }
                if let error {
                    self.handleRecognitionError(error as NSError, handsFree: self.handsFree)
                } else if let result, result.isFinal {
                    self.stopAudio()
                    self.task = nil
                    self.request = nil
                    self.pendingFinal = result.bestTranscription.formattedString
                    if self.releaseRequested || self.handsFree {
                        self.deliverFinal()
                    } else {
                        self.status = "Speech complete. Release the shortcut to use this command."
                    }
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isListening = true
            status = "Listening — \(recognitionMode)."
            if handsFree {
                sessionTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                    guard let self, self.generation == current, !self.releaseRequested else { return }
                    if self.transcript.isEmpty {
                        self.cancel()
                        self.onIdle?()
                    } else { self.finish() }
                }
            }
        } catch {
            cancel()
            status = error.localizedDescription
            throw error
        }
    }

    func finish() {
        if isStarting {
            cancel()
            status = "Released before the microphone was ready. Hold the shortcut to try again."
            return
        }
        guard !releaseRequested, request != nil || pendingFinal != nil else { return }
        releaseRequested = true
        silenceTask?.cancel()
        let current = generation
        finalTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, self.generation == current else { return }
            self.fail("Speech recognition did not finish. Please try again.")
        }
        if pendingFinal != nil {
            deliverFinal()
        } else {
            stopAudio()
            status = "Finishing — \(recognitionMode)."
            // Finish buffered audio. Only Apple's final recognition may run a command.
            task?.finish()
        }
    }

    func cancel() {
        silenceTask?.cancel(); silenceTask = nil
        sessionTask?.cancel(); sessionTask = nil
        finalTask?.cancel(); finalTask = nil
        generation = UUID()
        isStarting = false
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        pendingFinal = nil
        releaseRequested = false
        status = "Cancelled."
    }

    private func stopAudio() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // Serialize endAudio with an audio callback that was already in progress.
        let request = self.request
        audioGate?.withLock { acceptingAudio in
            if acceptingAudio {
                acceptingAudio = false
                request?.endAudio()
            }
        }
        audioGate = nil
        isListening = false
        audioLevel = 0
    }

    private func deliverFinal() {
        guard let final = pendingFinal else { return }
        let text = final.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if handsFree { cancel(); onIdle?(); return }
            fail("No speech was recognised.")
            return
        }
        silenceTask?.cancel(); silenceTask = nil
        sessionTask?.cancel(); sessionTask = nil
        finalTask?.cancel(); finalTask = nil
        generation = UUID()
        pendingFinal = nil
        task = nil
        request = nil
        transcript = text
        status = "Recognised — \(recognitionMode)."
        onFinal?(text)
    }

    // Keep an empty hands-free session alive after Apple's normal silence timeout.
    // Never execute partial text or suppress unrelated recognition failures.
    func handleRecognitionError(_ error: NSError, handsFree: Bool) {
        if handsFree, transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           error.domain == "kAFAssistantErrorDomain", error.code == 1110 {
            cancel()
            status = "Still listening…"
            let current = generation
            sessionTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                guard let self, self.generation == current else { return }
                self.onIdle?()
            }
            return
        }
        var code = "\(error.domain) \(error.code)"
        if let cause = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            code += "; \(cause.domain) \(cause.code)"
        }
        fail("Apple speech: \(error.localizedDescription) (\(code)).")
    }

    private func fail(_ message: String) {
        cancel()
        status = message
        onFailure?(message)
    }
}

struct SpeechInputError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
