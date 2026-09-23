import Foundation
import CoreGraphics

#if canImport(AppKit)
import AppKit
#endif

/// Geometry representing screen bounds and notch / auxiliary areas.
/// Can be constructed directly from NSScreen or with pure CG geometry for testing.
public struct ScreenGeometry: Equatable, Sendable {
    public let fullFrame: CGRect
    public let visibleFrame: CGRect
    public let safeAreaInsets: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat)
    public let auxTopLeft: CGRect?
    public let auxTopRight: CGRect?
    public let hasNotch: Bool

    public init(
        fullFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaInsets: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) = (0, 0, 0, 0),
        auxTopLeft: CGRect? = nil,
        auxTopRight: CGRect? = nil,
        hasNotch: Bool = false
    ) {
        self.fullFrame = fullFrame
        self.visibleFrame = visibleFrame
        self.safeAreaInsets = safeAreaInsets
        self.auxTopLeft = auxTopLeft
        self.auxTopRight = auxTopRight
        self.hasNotch = hasNotch
    }

    public static func == (lhs: ScreenGeometry, rhs: ScreenGeometry) -> Bool {
        lhs.fullFrame == rhs.fullFrame &&
        lhs.visibleFrame == rhs.visibleFrame &&
        lhs.safeAreaInsets.top == rhs.safeAreaInsets.top &&
        lhs.safeAreaInsets.left == rhs.safeAreaInsets.left &&
        lhs.safeAreaInsets.bottom == rhs.safeAreaInsets.bottom &&
        lhs.safeAreaInsets.right == rhs.safeAreaInsets.right &&
        lhs.auxTopLeft == rhs.auxTopLeft &&
        lhs.auxTopRight == rhs.auxTopRight &&
        lhs.hasNotch == rhs.hasNotch
    }
}

public struct SplitBands: Equatable, Sendable {
    public let leftBand: CGRect
    public let rightBand: CGRect
    public let menuBarHeight: CGFloat

    public init(leftBand: CGRect, rightBand: CGRect, menuBarHeight: CGFloat) {
        self.leftBand = leftBand
        self.rightBand = rightBand
        self.menuBarHeight = menuBarHeight
    }
}

public enum NotchLayout {
    /// Space kept between a capsule and the notch itself.
    public static let defaultGap: CGFloat = 6
    /// Space kept from the outer screen edge on a notchless display.
    public static let defaultEdgeInset: CGFloat = 10

    /// Where the two capsules hang: flush against the notch, centred in the strip beside it.
    public struct IslandAnchors: Equatable, Sendable {
        /// Trailing edge of the left capsule — the notch's own left edge.
        public let leftEdge: CGFloat
        /// Leading edge of the right capsule — the notch's own right edge.
        public let rightEdge: CGFloat
        /// The strip the capsules sit in: the menu-bar band either side of the notch.
        public let strip: CGRect
        /// How wide each capsule may grow before it reaches the outer edge of its side.
        public let leftRoom: CGFloat
        public let rightRoom: CGFloat
        public let hasNotch: Bool
    }

    /// Pure geometry for the island. On a notched display the capsules hang off the notch's own
    /// edges inside the 32 pt menu-bar strip; without a notch they sit either side of the centre.
    public static func anchors(
        for geometry: ScreenGeometry,
        gap: CGFloat = defaultGap,
        edgeInset: CGFloat = defaultEdgeInset
    ) -> IslandAnchors {
        if geometry.hasNotch, let auxLeft = geometry.auxTopLeft, let auxRight = geometry.auxTopRight {
            let strip = CGRect(
                x: geometry.fullFrame.minX,
                y: auxLeft.minY,
                width: geometry.fullFrame.width,
                height: auxLeft.height
            )
            return IslandAnchors(
                leftEdge: auxLeft.maxX - gap,
                rightEdge: auxRight.minX + gap,
                strip: strip,
                leftRoom: max(0, auxLeft.width - gap - edgeInset),
                rightRoom: max(0, auxRight.width - gap - edgeInset),
                hasNotch: true
            )
        }

        let menuBarHeight = max(24.0, geometry.fullFrame.maxY - geometry.visibleFrame.maxY)
        let strip = CGRect(
            x: geometry.fullFrame.minX,
            y: geometry.fullFrame.maxY - menuBarHeight,
            width: geometry.fullFrame.width,
            height: menuBarHeight
        )
        let centre = geometry.fullFrame.midX
        let room = max(0, strip.width / 2 - gap - edgeInset)
        return IslandAnchors(
            leftEdge: centre - gap,
            rightEdge: centre + gap,
            strip: strip,
            leftRoom: room,
            rightRoom: room,
            hasNotch: false
        )
    }

    /// Pure function computing left and right usable bands and menu bar height from ScreenGeometry.
    public static func computeBands(for geometry: ScreenGeometry, inset: CGFloat = 8.0) -> SplitBands {
        let menuBarHeight = max(24.0, geometry.fullFrame.maxY - geometry.visibleFrame.maxY)
        let topY = geometry.fullFrame.maxY - menuBarHeight

        if geometry.hasNotch, let auxLeft = geometry.auxTopLeft, let auxRight = geometry.auxTopRight {
            let leftBand = CGRect(
                x: auxLeft.origin.x + inset,
                y: auxLeft.origin.y + (auxLeft.height - (menuBarHeight - inset * 2)) / 2.0,
                width: max(0, auxLeft.width - inset * 2),
                height: max(0, menuBarHeight - inset * 2)
            )
            let rightBand = CGRect(
                x: auxRight.origin.x + inset,
                y: auxRight.origin.y + (auxRight.height - (menuBarHeight - inset * 2)) / 2.0,
                width: max(0, auxRight.width - inset * 2),
                height: max(0, menuBarHeight - inset * 2)
            )
            return SplitBands(leftBand: leftBand, rightBand: rightBand, menuBarHeight: menuBarHeight)
        }

        // Notchless display fallback: split the menu-bar strip into left and right halves
        let halfWidth = geometry.fullFrame.width / 2.0
        let bandHeight = max(0, menuBarHeight - inset * 2)
        let bandY = topY + inset

        let leftBand = CGRect(
            x: geometry.fullFrame.origin.x + inset,
            y: bandY,
            width: max(0, halfWidth - inset * 2),
            height: bandHeight
        )
        let rightBand = CGRect(
            x: geometry.fullFrame.origin.x + halfWidth + inset,
            y: bandY,
            width: max(0, halfWidth - inset * 2),
            height: bandHeight
        )
        return SplitBands(leftBand: leftBand, rightBand: rightBand, menuBarHeight: menuBarHeight)
    }

    #if canImport(AppKit)
    @MainActor
    public static func geometry(from screen: NSScreen) -> ScreenGeometry {
        let full = screen.frame
        let visible = screen.visibleFrame
        var auxLeft: CGRect? = nil
        var auxRight: CGRect? = nil
        var hasNotch = false

        if #available(macOS 12.0, *) {
            if let left = screen.auxiliaryTopLeftArea, left.width > 0 {
                auxLeft = left
                hasNotch = true
            }
            if let right = screen.auxiliaryTopRightArea, right.width > 0 {
                auxRight = right
                hasNotch = true
            }
        }

        let insets = (top: CGFloat(0), left: CGFloat(0), bottom: CGFloat(0), right: CGFloat(0))
        return ScreenGeometry(
            fullFrame: full,
            visibleFrame: visible,
            safeAreaInsets: insets,
            auxTopLeft: auxLeft,
            auxTopRight: auxRight,
            hasNotch: hasNotch
        )
    }
    #endif
}
