import AppKit
import ApplicationServices

/// Private WindowServer (CGS / SkyLight) and HIServices calls, resolved at runtime with dlsym.
/// A missing symbol never crashes: each wrapper reports "unavailable" and callers fall back.
enum Private {
    private static let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    private static func sym<T>(_ names: String..., as type: T.Type) -> T? {
        for n in names {
            if let p = dlsym(handle, n) { return unsafeBitCast(p, to: type) }
        }
        return nil
    }

    private typealias ConnFn = @convention(c) () -> Int32
    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindowSpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias MoveWindowsFn = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let connection: Int32? = sym("CGSMainConnectionID", "SLSMainConnectionID", as: ConnFn.self).map { $0() }

    // MARK: Spaces

    private static let copyDisplaySpacesFn = sym("CGSCopyManagedDisplaySpaces", "SLSCopyManagedDisplaySpaces", as: CopyDisplaySpacesFn.self)
    private static let copyWindowSpacesFn = sym("CGSCopySpacesForWindows", "SLSCopySpacesForWindows", as: CopyWindowSpacesFn.self)
    private static let addToSpacesFn = sym("CGSAddWindowsToSpaces", "SLSAddWindowsToSpaces", as: MoveWindowsFn.self)
    private static let removeFromSpacesFn = sym("CGSRemoveWindowsFromSpaces", "SLSRemoveWindowsFromSpaces", as: MoveWindowsFn.self)

    static var spacesAvailable: Bool {
        connection != nil && copyDisplaySpacesFn != nil && copyWindowSpacesFn != nil
            && addToSpacesFn != nil && removeFromSpacesFn != nil && displaySpaces() != nil
    }

    struct DisplaySpaces {
        /// Display UUID string, or "Main" when "Displays have separate Spaces" is off.
        let display: String
        let current: UInt64
        /// Desktop (type 0) as opposed to a full-screen / Split View Space (type 4).
        let currentIsDesktop: Bool
        let all: [UInt64]
        let desktops: [UInt64]
    }

    static func displaySpaces() -> [DisplaySpaces]? {
        guard let cid = connection, let fn = copyDisplaySpacesFn,
              let arr = fn(cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        func id(_ d: [String: Any]?) -> UInt64? { (d?["ManagedSpaceID"] as? NSNumber)?.uint64Value }
        func type(_ d: [String: Any]?) -> Int { (d?["type"] as? NSNumber)?.intValue ?? -1 }
        let result = arr.compactMap { entry -> DisplaySpaces? in
            guard let display = entry["Display Identifier"] as? String,
                  let cur = entry["Current Space"] as? [String: Any], let curID = id(cur) else { return nil }
            let spaces = entry["Spaces"] as? [[String: Any]] ?? []
            return DisplaySpaces(display: display, current: curID, currentIsDesktop: type(cur) == 0,
                                 all: spaces.compactMap { id($0) },
                                 desktops: spaces.filter { type($0) == 0 }.compactMap { id($0) })
        }
        return result.isEmpty ? nil : result
    }

    static func spaces(ofWindow window: Int) -> [UInt64] {
        guard let cid = connection, let fn = copyWindowSpacesFn,
              let arr = fn(cid, 0x7, [window] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return arr.map(\.uint64Value)
    }

    /// Makes `window` a member of exactly `space`.
    static func assign(window: Int, to space: UInt64, removingFrom others: [UInt64]) {
        guard let cid = connection, let add = addToSpacesFn, let remove = removeFromSpacesFn else { return }
        let w = [window] as CFArray
        add(cid, w, [NSNumber(value: space)] as CFArray)
        let rest = others.filter { $0 != space }.map { NSNumber(value: $0) }
        if !rest.isEmpty { remove(cid, w, rest as CFArray) }
    }

    // MARK: Accessibility element -> window number

    private static let axGetWindowFn = sym("_AXUIElementGetWindow", as: AXGetWindowFn.self)

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindowFn else { return nil }
        var id: CGWindowID = 0
        return fn(element, &id) == .success && id != 0 ? id : nil
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var uuidString: String? {
        guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Frame in CoreGraphics global coordinates (top-left origin), to compare with CGWindowList bounds.
    var cgFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Height of the menu bar strip at the top (0 when it auto-hides).
    var menuBarInset: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }
}
