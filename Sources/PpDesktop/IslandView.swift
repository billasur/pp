import SwiftUI
import AppKit
import PpCore

/// Geometry shared by both capsules, so the pair reads as one object continued around the notch.
public enum IslandMetrics {
    /// Capsule height. The notch strip is 32 pt on a notched Mac; 28 keeps a 2 pt breathing
    /// gap above and below and matches the menu bar's own proportions.
    public static let height: CGFloat = 28
    public static let padH: CGFloat = 10
    public static let orb: CGFloat = 19
    public static let gap: CGFloat = 7
    public static let cancel: CGFloat = 15
    /// Space kept between a capsule and the notch, and from the outer screen edge.
    public static let gapToNotch: CGFloat = NotchLayout.defaultGap
    public static let edgeInset: CGFloat = NotchLayout.defaultEdgeInset
}

extension IslandState {
    /// The dismiss button is offered whenever there is something to dismiss.
    var offersDismiss: Bool { self != .idle }

    /// The orb animates continuously only while something is happening.
    var isLive: Bool {
        switch self {
        case .idle: return false
        case .listening, .heard, .working, .alarm: return true
        case .result, .error: return true
        }
    }

    /// True while the microphone is open, so the orb reacts to the voice rather than to a timer.
    var hearsVoices: Bool {
        if case .listening = self { return true }
        if case .heard = self { return true }
        return false
    }

    /// Colour and motion per state: blue and calm at rest, Siri's own range while listening,
    /// green for a verified result, amber for a problem, red for a ringing alarm.
    var orbPalette: OrbPalette {
        switch self {
        case .idle:
            return OrbPalette(
                inner: Color(red: 0.34, green: 0.62, blue: 0.86),
                outer: Color(red: 0.07, green: 0.18, blue: 0.36),
                plasma: [Color(red: 0.30, green: 0.85, blue: 0.90),
                         Color(red: 0.36, green: 0.51, blue: 0.95)],
                speed: 0.45, energy: 0.15)
        case .listening, .heard:
            return OrbPalette(
                inner: Color(red: 0.36, green: 0.72, blue: 0.98),
                outer: Color(red: 0.10, green: 0.14, blue: 0.40),
                plasma: [Color(red: 0.28, green: 0.88, blue: 0.98),
                         Color(red: 0.42, green: 0.52, blue: 1.00),
                         Color(red: 0.76, green: 0.45, blue: 0.98),
                         Color(red: 0.98, green: 0.45, blue: 0.78)],
                speed: 1.15, energy: 0)
        case .working:
            return OrbPalette(
                inner: Color(red: 0.40, green: 0.62, blue: 1.00),
                outer: Color(red: 0.10, green: 0.13, blue: 0.42),
                plasma: [Color(red: 0.35, green: 0.70, blue: 1.00),
                         Color(red: 0.55, green: 0.45, blue: 1.00),
                         Color(red: 0.30, green: 0.85, blue: 0.92)],
                speed: 1.9, energy: 0.45)
        case .result:
            return OrbPalette(
                inner: Color(red: 0.40, green: 0.88, blue: 0.62),
                outer: Color(red: 0.06, green: 0.26, blue: 0.20),
                plasma: [Color(red: 0.36, green: 0.92, blue: 0.66),
                         Color(red: 0.22, green: 0.80, blue: 0.78)],
                speed: 0.9, energy: 0.25)
        case .error:
            return OrbPalette(
                inner: Color(red: 0.98, green: 0.76, blue: 0.36),
                outer: Color(red: 0.34, green: 0.20, blue: 0.04),
                plasma: [Color(red: 1.00, green: 0.78, blue: 0.36),
                         Color(red: 0.98, green: 0.55, blue: 0.30)],
                speed: 0.9, energy: 0.3)
        case .alarm:
            return OrbPalette(
                inner: Color(red: 1.00, green: 0.48, blue: 0.44),
                outer: Color(red: 0.38, green: 0.06, blue: 0.08),
                plasma: [Color(red: 1.00, green: 0.42, blue: 0.38),
                         Color(red: 0.98, green: 0.70, blue: 0.40),
                         Color(red: 1.00, green: 0.30, blue: 0.42)],
                speed: 2.6, energy: 0.7)
        }
    }
}

public struct OrbPalette: Sendable {
    let inner: Color
    let outer: Color
    let plasma: [Color]
    let speed: Double
    let energy: Double
}

/// The black capsule the notch is made of, continued either side of it.
struct IslandCapsule: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.black.opacity(0.86))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.16), .white.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.30), radius: 6, y: 2)
    }
}

/// Left capsule: the voice orb, and a dismiss control once there is something to dismiss.
public struct LeftIslandView: View {
    public let state: IslandState
    public let audioLevel: Double
    public let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        state: IslandState,
        audioLevel: Double = 0.0,
        onCancel: @escaping () -> Void = {}
    ) {
        self.state = state
        self.audioLevel = audioLevel
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: IslandMetrics.gap) {
            VoiceOrb(state: state, level: audioLevel, reduceMotion: reduceMotion)
                .frame(width: IslandMetrics.orb, height: IslandMetrics.orb)

            if state.offersDismiss {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: IslandMetrics.cancel, height: IslandMetrics.cancel)
                        .contentShape(Circle())
                }
                .buttonStyle(DimOnHoverButtonStyle())
                .help(state == .alarm ? "Stop the alarm" : "Cancel")
            }
        }
        .padding(.horizontal, IslandMetrics.padH)
        .frame(height: IslandMetrics.height)
        .background(IslandCapsule())
        .clipShape(Capsule(style: .continuous))
        .preferredColorScheme(.dark)
    }
}

/// Right capsule: the headline and, while listening, the live transcript.
public struct RightIslandView: View {
    public let state: IslandState
    public let headline: String
    public let detail: String

    public init(state: IslandState, headline: String, detail: String = "") {
        self.state = state
        self.headline = headline
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headlineText)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.1)
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.middle)
            if !detailText.isEmpty {
                Text(detailText)
                    .font(.system(size: 11, weight: .regular))
                    .italic(isTranscript)
                    .foregroundStyle(.white.opacity(isTranscript ? 0.60 : 0.52))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, IslandMetrics.padH)
        .frame(height: IslandMetrics.height)
        .background(IslandCapsule())
        .clipShape(Capsule(style: .continuous))
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.16), value: headline)
        .animation(.easeInOut(duration: 0.16), value: detail)
    }

    private var isTranscript: Bool { detail.hasPrefix("heard:") }

    private var headlineText: String {
        switch state {
        case .idle:
            return headline.isEmpty ? "pp" : headline
        case .listening:
            return headline.isEmpty ? "Listening…" : headline
        case .heard(let text):
            return text.isEmpty ? headline : text
        case .working:
            return headline.isEmpty ? "Working…" : headline
        case .result(let text):
            return text.isEmpty ? headline : text
        case .error(let text):
            return text.isEmpty ? headline : text
        case .alarm:
            return headline.isEmpty ? "Alarm" : headline
        }
    }

    private var detailText: String { detail }
}

/// A small plasma sphere: three drifting gradients inside a glossy sphere, reacting to the
/// microphone while pp is listening. Any state, any level, it never exceeds 19 pt.
struct VoiceOrb: View {
    let state: IslandState
    let level: Double
    let reduceMotion: Bool

    var body: some View {
        Group {
            if reduceMotion {
                OrbCanvas(state: state, level: level, phase: 1.7)
            } else {
                TimelineView(.animation(minimumInterval: state.isLive ? 1.0 / 30.0 : 1.0 / 8.0)) { timeline in
                    OrbCanvas(state: state, level: level, phase: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .overlay { glyph }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .idle, .listening, .heard:
            EmptyView()
        case .working:
            SpinningArc()
        case .result:
            OrbGlyph(symbol: "checkmark", weight: .bold)
        case .error:
            OrbGlyph(symbol: "exclamationmark", weight: .bold)
        case .alarm:
            OrbGlyph(symbol: "bell.fill", weight: .semibold)
        }
    }
}

private struct OrbGlyph: View {
    let symbol: String
    let weight: Font.Weight

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: weight))
            .foregroundStyle(.white.opacity(0.95))
            .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
    }
}

private struct SpinningArc: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            OrbGlyph(symbol: "ellipsis", weight: .bold)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let turns = timeline.date.timeIntervalSinceReferenceDate * 0.9
                Circle()
                    .trim(from: 0.08, to: 0.62)
                    .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(turns * 360))
                    .padding(1.5)
                    .shadow(color: .black.opacity(0.35), radius: 1)
            }
        }
    }
}

private struct OrbCanvas: View {
    let state: IslandState
    let level: Double
    let phase: TimeInterval

    var body: some View {
        let palette = state.orbPalette
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let sphere = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

            let voice = state.hearsVoices ? min(1, max(0, level)) : 0
            let energy = max(palette.energy, voice)
            // A ringing alarm breathes fast, everything else breathes slowly.
            let pulseRate = state == .alarm ? 5.2 : 1.05
            let pulse = 1 + CGFloat(0.09 * sin(phase * pulseRate)) * (state == .alarm ? 2.2 : 1)

            // Base sphere, lit from the upper left.
            context.fill(
                Path(ellipseIn: sphere),
                with: .radialGradient(
                    Gradient(colors: [palette.inner, palette.outer]),
                    center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.35),
                    startRadius: 0, endRadius: radius * 1.5))

            // Plasma, clipped to the sphere.
            var plasma = context
            plasma.clip(to: Path(ellipseIn: sphere))
            plasma.blendMode = .plusLighter
            plasma.addFilter(.blur(radius: radius * 0.42))

            let colours = palette.plasma
            for (index, colour) in colours.enumerated() {
                let step = Double(index)
                let angle = phase * palette.speed * (index.isMultiple(of: 2) ? 1 : -0.85) + step * 2.1
                let drift = CGFloat(0.10 + 0.30 * energy) * radius * pulse
                let position = CGPoint(
                    x: center.x + CGFloat(cos(angle)) * drift,
                    y: center.y + CGFloat(sin(angle * 1.2)) * drift * 0.9)
                let blob = radius * (0.58 + 0.26 * CGFloat(sin(phase * 1.3 + step * 1.7)) + 0.30 * CGFloat(energy))
                let rect = CGRect(x: position.x - blob, y: position.y - blob, width: blob * 2, height: blob * 2)
                plasma.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [colour.opacity(0.85), colour.opacity(0)]),
                        center: position, startRadius: 0, endRadius: blob))
            }

            // Gloss, so it reads as a sphere rather than a light.
            var gloss = context
            gloss.clip(to: Path(ellipseIn: sphere))
            gloss.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 1.35)),
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.34), .white.opacity(0)]),
                    startPoint: CGPoint(x: center.x - radius * 0.35, y: center.y - radius),
                    endPoint: CGPoint(x: center.x, y: center.y)))

            // Rim.
            context.stroke(
                Path(ellipseIn: sphere.insetBy(dx: 0.4, dy: 0.4)),
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.28), .white.opacity(0.03)]),
                    startPoint: CGPoint(x: center.x, y: sphere.minY),
                    endPoint: CGPoint(x: center.x, y: sphere.maxY)),
                lineWidth: 0.75)
        }
    }
}

/// The dismiss control only lights up when the pointer is on it.
private struct DimOnHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.9 : 0.55))
            .contentShape(Circle())
    }
}
