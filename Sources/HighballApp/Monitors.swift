import AppKit
import ApplicationServices
import HighballKit

struct Monitor: Identifiable, Equatable {
    let id: String
    let name: String
    let bounds: CGRect

    /// Connected displays; `id` is the CoreGraphics display UUID, stable across reboots and replug.
    static func connected() -> [Monitor] {
        NSScreen.screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let uuid = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?.takeRetainedValue(),
                let str = CFUUIDCreateString(nil, uuid) as String?
            else { return nil }
            return Monitor(id: str, name: screen.localizedName, bounds: CGDisplayBounds(num.uint32Value))
        }
    }
}

enum WindowMover {
    static func ensureTrusted(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt, a non-Sendable global in Swift 6
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Moves the process's windows onto `target`. Windows already handled are skipped, so one the
    /// player drags afterwards is never fought. Returns how many were moved.
    static func move(pid: pid_t, to target: CGRect, alreadyMoved: inout [AXUIElement]) -> Int {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)  // a game busy loading must not stall us for the 6 s default
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return 0 }
        var moved = 0
        for window in windows where !alreadyMoved.contains(where: { CFEqual($0, window) }) {
            guard let size = read(window, kAXSizeAttribute, .cgSize, as: CGSize.self),
                let pos = read(window, kAXPositionAttribute, .cgPoint, as: CGPoint.self)
            else { continue }
            alreadyMoved.append(window)
            if MonitorPlacement.isOn(CGRect(origin: pos, size: size), target: target) { continue }
            let frame = MonitorPlacement.frame(for: size, on: target)
            var newSize = frame.size
            var newPos = frame.origin
            if let s = AXValueCreate(.cgSize, &newSize) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
            }
            if let p = AXValueCreate(.cgPoint, &newPos),
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) == .success
            {
                moved += 1
            }
        }
        return moved
    }

    private static func read<T>(_ el: AXUIElement, _ attr: String, _ type: AXValueType, as _: T.Type)
        -> T?
    {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let ax = v,
            CFGetTypeID(ax) == AXValueGetTypeID()
        else { return nil }
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        guard AXValueGetValue(ax as! AXValue, type, ptr) else { return nil }
        return ptr.pointee
    }
}
