import AVFoundation
import Foundation
import PpCore
import Speech

/// Apple's on-device dictation (`SpeechAnalyzer` + `DictationTranscriber`), macOS 26+.
///
/// This adds nothing to the bundle, runs on the Neural Engine, and auto-updates with
/// the OS. It is opt-in rather than the default: it has to earn that by matching the
/// existing recogniser on real command audio first, so `SpeechInput` keeps using the
/// proven path until someone runs the comparison.
///
/// Buffers must already be in `preferredFormat`. Convert before calling `append` if the
/// capture node runs at a different rate.
@available(macOS 26.0, *)
final class SpeechAnalyzerAdapter: @unchecked Sendable {
    enum AdapterError: LocalizedError {
        case unsupportedLocale(Locale)
        case noCompatibleAudioFormat
        case bufferFormatMismatch(expected: Double, got: Double)

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let locale):
                return "On-device dictation has no model for \(locale.identifier)."
            case .noCompatibleAudioFormat:
                return "The dictation engine did not offer a usable audio format."
            case .bufferFormatMismatch(let expected, let got):
                return "Audio arrived at \(Int(got)) Hz but the dictation engine needs \(Int(expected)) Hz."
            }
        }
    }

    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    let format: AVAudioFormat

    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pump: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    private(set) var isListening = false
    var onUpdate: ((SpeechUpdate) -> Void)?

    var engineDescription: String { "Apple on-device dictation (SpeechAnalyzer)" }

    private init(transcriber: DictationTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
    }

    /// Whether the platform can run this engine at all.
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Builds an adapter, optionally installing the language asset first.
    static func make(locale: Locale = .current, installAssetsIfNeeded: Bool = true) async throws -> SpeechAnalyzerAdapter {
        let supported = await DictationTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier.hasPrefix(locale.language.languageCode?.identifier ?? locale.identifier) })
                || supported.contains(locale) else {
            throw AdapterError.unsupportedLocale(locale)
        }

        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        if installAssetsIfNeeded, let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AdapterError.noCompatibleAudioFormat
        }
        try await analyzer.prepareToAnalyze(in: format)
        return SpeechAnalyzerAdapter(transcriber: transcriber, analyzer: analyzer, format: format)
    }

    /// Begins a recognition session. Safe to call once per capture.
    func start() {
        guard !isListening else { return }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        isListening = true

        pump = Task { [analyzer] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                // Reported through the results task's failure path below.
            }
        }

        let transcriber = self.transcriber
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self?.onUpdate?(SpeechUpdate(kind: result.isFinal ? .final : .partial, text: text))
                }
            } catch {
                self?.onUpdate?(SpeechUpdate(kind: .failure, text: error.localizedDescription))
            }
        }
    }

    /// Feeds captured audio. `buffer.format` must match `format`.
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard isListening else { return }
        guard buffer.format.sampleRate == format.sampleRate else {
            throw AdapterError.bufferFormatMismatch(expected: format.sampleRate, got: buffer.format.sampleRate)
        }
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends the utterance and waits for the final result.
    func finish() async {
        continuation?.finish()
        continuation = nil
        isListening = false
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        pump?.cancel()
        pump = nil
    }

    /// Stops immediately. Audio is dropped, never written anywhere.
    func cancel() {
        continuation?.finish()
        continuation = nil
        isListening = false
        resultsTask?.cancel()
        resultsTask = nil
        pump?.cancel()
        pump = nil
    }
}
