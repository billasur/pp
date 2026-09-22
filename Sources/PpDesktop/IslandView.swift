import SwiftUI
import AppKit

public enum IslandState: Equatable, Sendable {
    case idle
    case listening
    case working
    case result(text: String)
    case error(text: String)

    public var size: CGSize {
        switch self {
        case .idle:
            return CGSize(width: 220, height: 34)
        case .listening:
            return CGSize(width: 420, height: 64)
        case .working:
            return CGSize(width: 520, height: 96)
        case .result:
            return CGSize(width: 420, height: 64)
        case .error:
            return CGSize(width: 480, height: 72)
        }
    }

    public var autoHideDuration: TimeInterval? {
        switch self {
        case .idle:
            return nil
        case .listening:
            return nil
        case .working:
            return nil // .working never auto-hides
        case .result:
            return 2.5 // .result 2.5s
        case .error:
            return 6.0 // .error 6s
        }
    }
}

public struct IslandView: View {
    public let state: IslandState
    public let headline: String
    public let detail: String
    public let audioLevel: Double
    public let onCancel: () -> Void

    public init(
        state: IslandState,
        headline: String,
        detail: String,
        audioLevel: Double = 0.0,
        onCancel: @escaping () -> Void = {}
    ) {
        self.state = state
        self.headline = headline
        self.detail = detail
        self.audioLevel = audioLevel
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 12) {
            leadingIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(headlineText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !detailText.isEmpty {
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if state != .idle {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: state.size.width, height: state.size.height)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color.black.opacity(0.75)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.size)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch state {
        case .idle:
            Circle()
                .fill(Color.teal)
                .frame(width: 8, height: 8)
        case .listening:
            Circle()
                .fill(Color.teal)
                .frame(width: 10 + CGFloat(audioLevel * 6), height: 10 + CGFloat(audioLevel * 6))
                .animation(.easeInOut(duration: 0.08), value: audioLevel)
        case .working:
            ProgressView()
                .controlSize(.small)
                .colorInvert()
        case .result:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 14))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 14))
        }
    }

    private var headlineText: String {
        switch state {
        case .idle:
            return headline.isEmpty ? "pp" : headline
        case .listening:
            return headline.isEmpty ? "Listening…" : headline
        case .working:
            return headline.isEmpty ? "Working…" : headline
        case .result(let text):
            return text.isEmpty ? headline : text
        case .error(let text):
            return text.isEmpty ? headline : text
        }
    }

    private var detailText: String {
        switch state {
        case .idle, .listening, .working:
            return detail
        case .result, .error:
            return detail
        }
    }
}
