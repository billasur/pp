import AppKit
import SwiftUI

@MainActor
public final class IslandController: NSObject {
    private var panel: NSPanel?
    private var hideTimer: Timer?
    public private(set) var currentState: IslandState = .idle
    private var hostingView: NSHostingView<IslandView>?

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

        let panel = panel ?? createPanel(for: state)
        self.panel = panel

        let islandView = IslandView(
            state: state,
            headline: headline,
            detail: detail,
            audioLevel: audioLevel,
            onCancel: { [weak self] in
                self?.onCancelRequested?()
            }
        )

        if let hostingView = self.hostingView {
            hostingView.rootView = islandView
        } else {
            let hosting = NSHostingView(rootView: islandView)
            self.hostingView = hosting
            panel.contentView = hosting
        }

        updatePanelFrame(for: state)

        panel.orderFrontRegardless()

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
        panel?.orderOut(nil)
    }

    private func createPanel(for state: IslandState) -> NSPanel {
        let size = state.size
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // IslandView draws its own capsule shadow
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func updatePanelFrame(for state: IslandState) {
        guard let panel = self.panel else { return }
        let size = state.size

        guard let screen = NSScreen.main else {
            panel.setContentSize(size)
            return
        }

        let screenFrame = screen.visibleFrame
        // Center horizontally near top of screen (or below notch / menu bar)
        let x = screenFrame.midX - (size.width / 2.0)
        let y = screenFrame.maxY - size.height - 12.0

        let newFrame = NSRect(x: x, y: y, width: size.width, height: size.height)
        panel.setFrame(newFrame, display: true, animate: true)
    }
}
