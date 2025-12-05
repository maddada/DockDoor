import AppKit
import Defaults

/// Observes system-wide window activation changes to show highlight borders
/// This is used when "Only highlight when using DockDoor" is disabled
final class WindowHighlightObserver {
    static let shared = WindowHighlightObserver()

    private var isObserving = false
    private var axObserver: AXObserver?
    private var lastHighlightedWindowID: CGWindowID?
    private var currentApp: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var highlightEnabledObserver: Defaults.Observation?
    private var onlyDockDoorObserver: Defaults.Observation?

    private init() {
        setupSettingsObservers()
    }

    private func setupSettingsObservers() {
        // Start/stop observing based on settings
        updateObservingState()

        // Observe settings changes
        highlightEnabledObserver = Defaults.observe(.highlightActiveWindow) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateObservingState()
            }
        }

        onlyDockDoorObserver = Defaults.observe(.highlightActiveWindowOnlyDockDoor) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateObservingState()
            }
        }
    }

    func updateObservingState() {
        let shouldObserve = Defaults[.highlightActiveWindow] && !Defaults[.highlightActiveWindowOnlyDockDoor]

        if shouldObserve, !isObserving {
            startObserving()
        } else if !shouldObserve, isObserving {
            stopObserving()
        }
    }

    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        // Observe app activation changes
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.handleAppActivation(app)
        }

        // Also observe the current frontmost app
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            setupWindowObserver(for: frontApp)
        }
    }

    private func stopObserving() {
        guard isObserving else { return }
        isObserving = false

        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }

        removeCurrentObserver()
    }

    private func handleAppActivation(_ app: NSRunningApplication) {
        // Don't highlight if this is a DockDoor-initiated switch
        // DockDoor's WindowUtil.bringWindowToFront already handles that
        guard Defaults[.highlightActiveWindow],
              !Defaults[.highlightActiveWindowOnlyDockDoor]
        else {
            return
        }

        setupWindowObserver(for: app)
        highlightFocusedWindow(for: app)
    }

    private func setupWindowObserver(for app: NSRunningApplication) {
        removeCurrentObserver()
        currentApp = app

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var observer: AXObserver?
        let result = AXObserverCreate(app.processIdentifier, { _, element, notification, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<WindowHighlightObserver>.fromOpaque(refcon).takeUnretainedValue()
            observer.handleFocusChange(element: element, notification: notification as String)
        }, &observer)

        guard result == .success, let observer else { return }

        axObserver = observer

        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func removeCurrentObserver() {
        if let observer = axObserver, let app = currentApp {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
        }
        axObserver = nil
        currentApp = nil
    }

    private func handleFocusChange(element: AXUIElement, notification: String) {
        guard notification == kAXFocusedWindowChangedNotification as String else { return }

        // Small delay to avoid conflicting with DockDoor's own highlight
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.highlightWindow(element: element)
        }
    }

    private func highlightFocusedWindow(for app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let windowElement = focusedWindow else { return }

        // Small delay to let the window fully activate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.highlightWindow(element: windowElement as! AXUIElement)
        }
    }

    private func highlightWindow(element: AXUIElement) {
        guard Defaults[.highlightActiveWindow],
              !Defaults[.highlightActiveWindowOnlyDockDoor]
        else {
            return
        }

        // Get window ID to avoid highlighting the same window twice
        var windowID: CGWindowID = 0
        if _AXUIElementGetWindow(element, &windowID) != .success {
            return
        }

        // Skip if we just highlighted this window
        if windowID == lastHighlightedWindowID {
            return
        }
        lastHighlightedWindowID = windowID

        // Get window frame
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else {
            return
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        let frame = CGRect(origin: position, size: size)

        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else {
            return
        }

        // Convert coordinates (AX uses top-left origin)
        let screenFrame = screen.frame
        let flippedY = screenFrame.maxY - frame.maxY

        let convertedFrame = CGRect(
            x: frame.origin.x,
            y: flippedY,
            width: frame.width,
            height: frame.height
        )

        WindowHighlightCoordinator.shared.showHighlight(around: convertedFrame, on: screen)
    }

    /// Call this to reset the last highlighted window ID
    /// This allows re-highlighting the same window if needed
    func resetLastHighlighted() {
        lastHighlightedWindowID = nil
    }
}

// Private API declaration
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
