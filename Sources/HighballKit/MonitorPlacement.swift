import CoreGraphics

public enum MonitorPlacement {
    /// Frame for a window of `size` on the display whose bounds (top-left origin, as AX and CGDisplayBounds use) are `target`: shrunk to fit, centred.
    public static func frame(for size: CGSize, on target: CGRect) -> CGRect {
        let w = min(size.width, target.width)
        let h = min(size.height, target.height)
        return CGRect(
            x: target.minX + (target.width - w) / 2,
            y: target.minY + (target.height - h) / 2,
            width: w, height: h)
    }

    /// Whether the window's centre is already on `target`.
    public static func isOn(_ window: CGRect, target: CGRect) -> Bool {
        target.contains(CGPoint(x: window.midX, y: window.midY))
    }
}
