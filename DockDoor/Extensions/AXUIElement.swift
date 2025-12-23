import ApplicationServices.HIServices.AXActionConstants
import ApplicationServices.HIServices.AXAttributeConstants
import ApplicationServices.HIServices.AXError
import ApplicationServices.HIServices.AXRoleConstants
import ApplicationServices.HIServices.AXUIElement
import ApplicationServices.HIServices.AXValue
import Cocoa

// NOTE: Borrows code from https://github.com/lwouis/alt-tab-macos/blob/master/src/api-wrappers/AXUIElement.swift

extension AXUIElement {
    func axCallWhichCanThrow<T>(_ result: AXError, _ successValue: inout T) throws -> T? {
        switch result {
        case .success: return successValue
        // .cannotComplete can happen if the app is unresponsive; we throw in that case to retry until the call succeeds
        case .cannotComplete: throw AxError.runtimeError
        // for other errors it's pointless to retry
        default: return nil
        }
    }

    func cgWindowId() throws -> CGWindowID? {
        var id = CGWindowID(0)
        return try axCallWhichCanThrow(_AXUIElementGetWindow(self, &id), &id)
    }

    func pid() throws -> pid_t? {
        var pid = pid_t(0)
        return try axCallWhichCanThrow(AXUIElementGetPid(self, &pid), &pid)
    }

    func attribute<T>(_ key: String, _ _: T.Type) throws -> T? {
        var value: AnyObject?
        return try axCallWhichCanThrow(AXUIElementCopyAttributeValue(self, key as CFString, &value), &value) as? T
    }

    private func value<T>(_ key: String, _ target: T, _ type: AXValueType) throws -> T? {
        if let a = try attribute(key, AXValue.self) {
            var value = target
            let success = withUnsafeMutablePointer(to: &value) { ptr in
                AXValueGetValue(a, type, ptr)
            }
            return success ? value : nil
        }
        return nil
    }

    func position() throws -> CGPoint? {
        try value(kAXPositionAttribute, CGPoint.zero, .cgPoint)
    }

    func size() throws -> CGSize? {
        try value(kAXSizeAttribute, CGSize.zero, .cgSize)
    }

    func title() throws -> String? {
        try attribute(kAXTitleAttribute, String.self)
    }

    func parent() throws -> AXUIElement? {
        try attribute(kAXParentAttribute, AXUIElement.self)
    }

    func children() throws -> [AXUIElement]? {
        try attribute(kAXChildrenAttribute, [AXUIElement].self)
    }

    func windows() throws -> [AXUIElement]? {
        try attribute(kAXWindowsAttribute, [AXUIElement].self)
    }

    /// Brute-force window enumeration by iterating over AXUIElementIDs.
    /// For special apps (Steam, Android emulators, etc.), we accept windows with non-standard subroles.
    /// - Parameters:
    ///   - pid: The process identifier
    ///   - app: Optional app for special handling of non-standard subroles
    /// - Returns: Array of AXUIElement windows
    static func windowsByBruteForce(_ pid: pid_t, app: NSRunningApplication? = nil) -> [AXUIElement] {
        var token = Data(count: 20)
        token.replaceSubrange(0 ..< 4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8 ..< 12, with: withUnsafeBytes(of: Int32(0x636F_636F)) { Data($0) })

        var results: [AXUIElement] = []
        let isSpecialApp = app.map { SpecialWindowHandlers.isSpecialAppWithNonStandardSubrole(app: $0) } ?? false

        for axId: AXUIElementID in 0 ..< 1000 {
            token.replaceSubrange(12 ..< 20, with: withUnsafeBytes(of: axId) { Data($0) })
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else {
                continue
            }

            // Check role first - must be a window
            guard let role = try? el.role(), role == kAXWindowRole else {
                continue
            }

            let subrole = try? el.subrole()

            // For special apps (Steam, Android emulators, etc.), accept windows with any subrole
            if isSpecialApp {
                // Still filter out obvious non-windows for special apps
                // Steam dropdown menus have role == nil when switching quickly
                if let subrole, subrole == "AXSystemDialog" {
                    continue // Skip system dialogs like tooltips
                }
                logWindowDiscovery("[windowsByBruteForce] Accepted window from special app: \(app?.localizedName ?? "unknown"), subrole: \(subrole ?? "nil")")
                results.append(el)
                continue
            }

            // For normal apps, require standard subroles
            if let subrole, [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole) {
                results.append(el)
            }
        }
        return results
    }

    /// Gets all windows for an app using both standard AX API and brute-force enumeration.
    /// This ensures we catch windows on other spaces and from apps with non-standard configurations.
    /// - Parameters:
    ///   - pid: The process identifier
    ///   - appElement: The app's AXUIElement
    ///   - app: Optional app for special handling of non-standard subroles
    /// - Returns: Array of AXUIElement windows
    static func allWindows(_ pid: pid_t, appElement: AXUIElement, app: NSRunningApplication? = nil) -> [AXUIElement] {
        var set = Set<AXUIElement>()
        if let maybe = try? appElement.windows() {
            set.formUnion(maybe)
        }
        let brute = windowsByBruteForce(pid, app: app)
        set.formUnion(brute)
        return Array(set)
    }

    func isMinimized() throws -> Bool {
        let result = try attribute(kAXMinimizedAttribute, Bool.self) == true
        return result
    }

    func isFullscreen() throws -> Bool {
        try attribute(kAXFullscreenAttribute, Bool.self) == true
    }

    func focusedWindow() throws -> AXUIElement? {
        try attribute(kAXFocusedWindowAttribute, AXUIElement.self)
    }

    func role() throws -> String? {
        try attribute(kAXRoleAttribute, String.self)
    }

    func subrole() throws -> String? {
        try attribute(kAXSubroleAttribute, String.self)
    }

    func appIsRunning() throws -> Bool? {
        try attribute(kAXIsApplicationRunningAttribute, Bool.self)
    }

    func closeButton() throws -> AXUIElement? {
        try attribute(kAXCloseButtonAttribute, AXUIElement.self)
    }

    func minimizeButton() throws -> AXUIElement? {
        try attribute(kAXMinimizeButtonAttribute, AXUIElement.self)
    }

    func zoomButton() throws -> AXUIElement? {
        try attribute(kAXZoomButtonAttribute, AXUIElement.self)
    }

    func fullscreenButton() throws -> AXUIElement? {
        try attribute(kAXFullscreenAttribute, AXUIElement.self)
    }

    func subscribeToNotification(_ axObserver: AXObserver, _ notification: String, _ callback: (() -> Void)? = nil) throws {
        let result = AXObserverAddNotification(axObserver, self, notification as CFString, nil)
        if result == .success || result == .notificationAlreadyRegistered {
            callback?()
        } else if result != .notificationUnsupported, result != .notImplemented {
            throw AxError.runtimeError
        }
    }

    func setAttribute(_ key: String, _ value: Any) throws {
        var unused: Void = ()
        try axCallWhichCanThrow(AXUIElementSetAttributeValue(self, key as CFString, value as CFTypeRef), &unused)
    }

    func performAction(_ action: String) throws {
        var unused: Void = ()
        try axCallWhichCanThrow(AXUIElementPerformAction(self, action as CFString), &unused)
    }
}

enum AxError: Error {
    case runtimeError
}

typealias AXUIElementID = UInt64
