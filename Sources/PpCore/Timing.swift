import Foundation

/// Collects named timing marks across a session lifecycle and emits structured metrics to timing.jsonl.
public actor Timing {
    public static let shared = Timing()

    public struct Mark: Codable, Sendable {
        public let name: String
        public let timestamp: TimeInterval // monotonic seconds
    }

    public struct SessionTiming: Codable, Sendable {
        public let sessionId: String
        public let marks: [Mark]
        public let totalDurationMs: Double
        public let recordedAt: Date

        public init(sessionId: String, marks: [Mark], totalDurationMs: Double, recordedAt: Date = Date()) {
            self.sessionId = sessionId
            self.marks = marks
            self.totalDurationMs = totalDurationMs
            self.recordedAt = recordedAt
        }
    }

    private var currentSessionId: String?
    private var currentMarks: [Mark] = []
    private let logFileURL: URL

    public init(logFileURL: URL? = nil) {
        if let logFileURL {
            self.logFileURL = logFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let ppDir = appSupport.appendingPathComponent("pp", isDirectory: true)
            try? FileManager.default.createDirectory(at: ppDir, withIntermediateDirectories: true)
            self.logFileURL = ppDir.appendingPathComponent("timing.jsonl")
        }
    }

    public func startSession(id: String = UUID().uuidString) {
        currentSessionId = id
        currentMarks = []
    }

    public func mark(_ name: String, monotonicTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        currentMarks.append(Mark(name: name, timestamp: monotonicTime))
    }

    @discardableResult
    public func finishSession() -> SessionTiming? {
        guard let sessionId = currentSessionId, !currentMarks.isEmpty else { return nil }

        let first = currentMarks.first!.timestamp
        let last = currentMarks.last!.timestamp
        let durationMs = (last - first) * 1000.0

        let session = SessionTiming(sessionId: sessionId, marks: currentMarks, totalDurationMs: durationMs)

        // Append line to timing.jsonl
        if let data = try? JSONEncoder().encode(session),
           let string = String(data: data, encoding: .utf8) {
            let line = string + "\n"
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                if let lineData = line.data(using: .utf8) {
                    fileHandle.write(lineData)
                }
                try? fileHandle.close()
            } else {
                try? line.write(to: logFileURL, atomically: true, encoding: .utf8)
            }
        }

        currentSessionId = nil
        currentMarks = []
        return session
    }

    public func getMarks() -> [Mark] {
        currentMarks
    }
}
