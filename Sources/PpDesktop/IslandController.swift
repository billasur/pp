import AppKit
import SwiftUI
import PpCore

/// Controls the two capsules flanking the notch (or the two halves of the menu bar).
/// - `leftPanel`: the voice orb and, when there is something to dismiss, the ✕ control.
/// - `rightPanel`: the headline and the live transcript.
///
/// Both panels hug the notch's own edges, are sized to their content, and never take focus.
@MainActor
public final class IslandController: NSObject {
    private var leftPanel: NSPanel?
    private var rightPanel: NSPanel?
    private var hideTimer: Timer?
    public private(set) var currentState: IslandState = .idle
    private var leftHostingView: NSHostingView<LeftIslandView>?
    private var rightHostingView: NSHostingView<RightIslandView>?

    /// The state the current frames were laid out for. Frames are only recomputed when this
    /// changes, so the live transcript cannot make the capsule twitch while it is being spoken.
    private var laidOutState: IslandState?
    private var laidOutScreen: CGRect?

    public var onCancelRequested: (() -> Void)?

    public override init() {
        super.init()
    }

    public func show(
        state: IslandState,
        headline: String,
        detail: String = "",
        audioLevel: Double = 0.0
    ) {
        self.currentState = state
        hideTimer?.invalidate()
        hideTimer = nil

        let left = leftPanel ?? createPanel(name: "pp.island.left")
        self.leftPanel = left
        let right = rightPanel ?? createPanel(name: "pp.island.right")
        self.rightPanel = right

        let leftView = LeftIslandView(
            state: state,
            audioLevel: audioLevel,
            onCancel: { [weak self] in
                self?.onCancelRequested?()
            }
        )
        if let host = self.leftHostingView {
            host.rootView = leftView
        } else {
            let host = NSHostingView(rootView: leftView)
            host.layoutSubtreeIfNeeded()
            self.leftHostingView = host
            left.contentView = host
        }

        let rightView = RightIslandView(
            state: state,
            headline: headline,
            detail: detail
        )
        if let host = self.rightHostingView {
            host.rootView = rightView
        } else {
            let host = NSHostingView(rootView: rightView)
            host.layoutSubtreeIfNeeded()
            self.rightHostingView = host
            right.contentView = host
        }

        let screenChanged = laidOutScreen != NSScreen.main?.frame
        if state != laidOutState || screenChanged {
            updatePanelsFrame(for: state, animated: laidOutState != nil)
            laidOutState = state
            laidOutScreen = NSScreen.main?.frame
        }

        left.orderFrontRegardless()
        right.orderFrontRegardless()

        if let duration = state.autoHideDuration {
            hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.hide()
                }
            }
        }
    }

    public func update(
        headline: String,
        detail: String = "",
        audioLevel: Double = 0.0
    ) {
        show(state: currentState, headline: headline, detail: detail, audioLevel: audioLevel)
    }

    public func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        leftPanel?.orderOut(nil)
        rightPanel?.orderOut(nil)
        laidOutState = nil
        laidOutScreen = nil
    }

    private func createPanel(name: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName(name)
        return panel
    }

    /// Lays out the pair: left capsule ending at the notch, right capsule starting at it, both
    /// vertically centred in the menu-bar strip and only as wide as what they are showing.
    private func updatePanelsFrame(for state: IslandState, animated: Bool) {
        guard let left = self.leftPanel, let right = self.rightPanel else { return }
        guard let screen = NSScreen.main else { return }

        let anchors = NotchLayout.anchors(for: NotchLayout.geometry(from: screen))
        let height = min(IslandMetrics.height, max(20, anchors.strip.height - 4))
        let y = anchors.strip.midY - height / 2

        let leftWidth = state.offersDismiss
            ? IslandMetrics.padH * 2 + IslandMetrics.orb + IslandMetrics.gap + IslandMetrics.cancel
            : IslandMetrics.padH * 2 + IslandMetrics.orb

        let idealRight = rightHostingView?.fittingSize.width ?? 0
        let rightWidth = min(max(idealRight, 96), max(96, anchors.rightRoom))

        let leftFrame = NSRect(x: anchors.leftEdge - leftWidth, y: y, width: leftWidth, height: height)
        let rightFrame = NSRect(x: anchors.rightEdge, y: y, width: rightWidth, height: height)

        guard animated else {
            left.setFrame(leftFrame, display: true, animate: false)
            right.setFrame(rightFrame, display: true, animate: false)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            left.animator().setFrame(leftFrame, display: true)
            right.animator().setFrame(rightFrame, display: true)
        }
    }
}
