import ApplicationServices
import Cocoa

// MARK: - Debug Logging

/// Log window discovery events for debugging
func logWindowDiscovery(_ message: String) {
    #if DEBUG
        print("[WindowDiscovery] \(message)")
    #endif
}

// Minimal provider used when we only have a CGWindowID (no SCWindow available)
struct AXFallbackProvider: WindowPropertiesProviding {
    let cgID: CGWindowID
    var windowID: CGWindowID { cgID }
    var frame: CGRect { .zero }
    var title: String? { nil }
    var owningApplicationBundleIdentifier: String? { nil }
    var owningApplicationProcessID: pid_t? { nil }
    var isOnScreen: Bool { true }
    var windowLayer: Int { 0 }
}

/// Heuristic mapping from AX window to CG window when _AXUIElementGetWindow fails
func mapAXToCG(axWindow: AXUIElement, candidates: [[String: AnyObject]], excluding: Set<CGWindowID>) -> CGWindowID? {
    let axTitle = (try? axWindow.title())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let axPos = try? axWindow.position()
    let axSize = try? axWindow.size()

    // 1) Exact title match among unused candidates
    if !axTitle.isEmpty {
        if let match = candidates.first(where: { desc in
            let title = (desc[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            return title == axTitle && !excluding.contains(wid)
        }) {
            return CGWindowID((match[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }
    }

    // 2) Geometry match within tolerance
    if let p = axPos, let s = axSize, s != .zero {
        let tol: CGFloat = 2.0
        if let match = candidates.first(where: { desc in
            let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            if excluding.contains(wid) { return false }
            let bounds = desc[kCGWindowBounds as String] as? [String: AnyObject]
            let rx = CGFloat((bounds?["X"] as? NSNumber)?.doubleValue ?? .infinity)
            let ry = CGFloat((bounds?["Y"] as? NSNumber)?.doubleValue ?? .infinity)
            let rw = CGFloat((bounds?["Width"] as? NSNumber)?.doubleValue ?? .infinity)
            let rh = CGFloat((bounds?["Height"] as? NSNumber)?.doubleValue ?? .infinity)
            let r = CGRect(x: rx, y: ry, width: rw, height: rh)
            let posMatch = abs(r.origin.x - p.x) <= tol && abs(r.origin.y - p.y) <= tol
            let sizeMatch = abs(r.size.width - s.width) <= tol && abs(r.size.height - s.height) <= tol
            return posMatch && sizeMatch
        }) {
            return CGWindowID((match[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }
    }

    // 3) Fuzzy title contains
    if !axTitle.isEmpty {
        if let match = candidates.first(where: { desc in
            let title = ((desc[kCGWindowName as String] as? String) ?? "").lowercased()
            let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            return !excluding.contains(wid) && title.contains(axTitle.lowercased())
        }) {
            return CGWindowID((match[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }
    }

    return nil
}

// MARK: - Shared Helper Functions

/// Returns CG window candidates for a given PID.
/// - Parameters:
///   - pid: The process identifier
///   - app: Optional app for special handling - if provided, may include windows from non-zero layers
///   - includeAllLayers: If true, include windows from all layers (not just layer 0)
/// - Returns: Array of CG window dictionaries
func getCGWindowCandidates(for pid: pid_t, app: NSRunningApplication? = nil, includeAllLayers: Bool = false) -> [[String: AnyObject]] {
    let cgAll = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]]) ?? []

    // Check if this is a special app that might have windows at non-zero layers
    let isSpecialApp = app.map { SpecialWindowHandlers.isSpecialAppWithNonStandardSubrole(app: $0) } ?? false
    let allowAllLayers = includeAllLayers || isSpecialApp

    let result = cgAll.filter { desc in
        let owner = (desc[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        guard owner == pid else { return false }

        let layer = (desc[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0

        if allowAllLayers {
            // For special apps, accept windows at any layer >= 0 (filter out negative layers like menus)
            // Also allow normal window level (0) for all apps
            let isValidLayer = layer >= 0 && layer <= 10 // Reasonable range for window layers
            if isValidLayer {
                logWindowDiscovery("[getCGWindowCandidates] Including window with layer \(layer) for special app (pid: \(pid))")
            }
            return isValidLayer
        } else {
            // For normal apps, only include layer 0
            return layer == 0
        }
    }

    logWindowDiscovery("[getCGWindowCandidates] Found \(result.count) CG windows for pid \(pid) (allowAllLayers: \(allowAllLayers))")
    return result
}

/// Finds the CG window entry matching a given window ID in the candidates list
func findCGEntry(for windowID: CGWindowID, in candidates: [[String: AnyObject]]) -> [String: AnyObject]? {
    candidates.first { desc in
        let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        return wid == windowID
    }
}

// MARK: - Shared Validation

let AXMinWindowSize: CGSize = .init(width: 100, height: 100)
/// Minimum height for windows (Finder copy dialogs can be narrow but wide)
let AXMinWindowHeight: CGFloat = 50

/// Validates an AX window candidate with optional special app handling.
/// - Parameters:
///   - axWindow: The AXUIElement to validate
///   - app: Optional app for special handling (Steam, Android emulators, etc.)
/// - Returns: true if the window should be considered for further processing
func isValidAXWindowCandidate(_ axWindow: AXUIElement, app: NSRunningApplication? = nil) -> Bool {
    // Check role first - must be a window
    guard let role = try? axWindow.role(), role == kAXWindowRole else {
        logWindowDiscovery("[isValidAXWindowCandidate] Rejected: role != kAXWindowRole")
        return false
    }

    let subrole = try? axWindow.subrole()
    let size = try? axWindow.size()
    let position = try? axWindow.position()

    // Basic size/position validation
    if let s = size, let p = position {
        if s == .zero || s.width < AXMinWindowSize.width || s.height < AXMinWindowHeight {
            logWindowDiscovery("[isValidAXWindowCandidate] Rejected: size too small (\(s.width)x\(s.height))")
            return false
        }
        if !p.x.isFinite || !p.y.isFinite {
            logWindowDiscovery("[isValidAXWindowCandidate] Rejected: invalid position")
            return false
        }
    }

    // If we have an app, use special handlers for apps with non-standard subroles
    if let app {
        // Check if this is a special app that uses non-standard subroles
        if SpecialWindowHandlers.isSpecialAppWithNonStandardSubrole(app: app) {
            // For special apps, we're more permissive - accept if it has role = window
            logWindowDiscovery("[isValidAXWindowCandidate] Accepted via special handler: \(app.localizedName ?? "unknown")")
            return true
        }
    }

    // Standard subrole check for normal apps
    if let subrole {
        let isStandardSubrole = [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole)
        if !isStandardSubrole {
            logWindowDiscovery("[isValidAXWindowCandidate] Rejected: non-standard subrole '\(subrole)' for app: \(app?.localizedName ?? "unknown")")
            return false
        }
    }

    return true
}

/// Legacy function for backward compatibility - calls the new version without app
func isValidAXWindowCandidateLegacy(_ axWindow: AXUIElement) -> Bool {
    isValidAXWindowCandidate(axWindow, app: nil)
}

/// Checks if a window is at least at normal window level.
/// For special apps (IINA, Keynote, etc.), this is more permissive.
/// - Parameters:
///   - id: The CGWindowID to check
///   - app: Optional app for special handling
/// - Returns: true if the window level is acceptable
func isAtLeastNormalLevel(_ id: CGWindowID, app: NSRunningApplication? = nil) -> Bool {
    let level = id.cgsLevel()
    let normalLevel = Int32(CGWindowLevelForKey(.normalWindow))

    // Normal check: level >= normalWindow (0)
    if level >= normalLevel {
        return true
    }

    // For special apps, be more permissive with level checks
    // Some apps during animations may temporarily have unusual levels
    if let app, SpecialWindowHandlers.isSpecialAppWithNonStandardSubrole(app: app) {
        // Accept any non-negative level for special apps
        logWindowDiscovery("[isAtLeastNormalLevel] Special app \(app.localizedName ?? "unknown") at level \(level) - accepting")
        return level >= -1 // Allow slight margin for edge cases
    }

    logWindowDiscovery("[isAtLeastNormalLevel] Rejected level \(level) (normalLevel: \(normalLevel))")
    return false
}

func isValidCGWindowCandidate(_ id: CGWindowID, in candidates: [[String: AnyObject]]) -> Bool {
    guard let match = candidates.first(where: { desc -> Bool in
        let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        return wid == id
    }) else { return false }

    let bounds = match[kCGWindowBounds as String] as? [String: AnyObject]
    let rw = CGFloat((bounds?["Width"] as? NSNumber)?.doubleValue ?? 0)
    let rh = CGFloat((bounds?["Height"] as? NSNumber)?.doubleValue ?? 0)
    let alpha = CGFloat((match[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0)
    if rw < AXMinWindowSize.width || rh < AXMinWindowSize.height { return false }
    if alpha <= 0.01 { return false }
    return true
}

// Returns the set of currently active Space IDs across all displays by
// inspecting on-screen, layer-0 windows and unioning their space IDs.
func currentActiveSpaceIDs() -> Set<Int> {
    var result = Set<Int>()
    guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] else { return result }
    for desc in list {
        let layer = (desc[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        let isOnscreen = (desc[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        guard layer == 0, isOnscreen else { continue }
        let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        for space in wid.cgsSpaces() {
            result.insert(Int(space))
        }
    }
    return result
}

// Decide if a window should be accepted considering on-screen state,
// ScreenCaptureKit presence, multi-Space, and window/app state.
func shouldAcceptWindow(axWindow: AXUIElement,
                        windowID: CGWindowID,
                        cgEntry: [String: AnyObject],
                        app: NSRunningApplication,
                        activeSpaceIDs: Set<Int>,
                        scBacked: Bool) -> Bool
{
    // Base: role/subrole, level, size/alpha checks already enforced by caller
    let isOnscreen = (cgEntry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false

    if isOnscreen || scBacked { return true }

    // If it has window controls, include even if not currently on-screen
    let axHasClose = (try? axWindow.closeButton())
    let axHasMinimize = (try? axWindow.minimizeButton())
    if axHasClose != nil || axHasMinimize != nil { return true }

    // If minimized/fullscreen or app hidden, include even if not currently on-screen
    let axIsFullscreen = (try? axWindow.isFullscreen()) ?? false
    let axIsMinimized = (try? axWindow.isMinimized()) ?? false
    if app.isHidden || axIsFullscreen || axIsMinimized { return true }

    // If assigned to other Space(s) than any active Space, include
    let windowSpaces = Set(windowID.cgsSpaces().map { Int($0) })
    if !windowSpaces.isEmpty, windowSpaces.isDisjoint(with: activeSpaceIDs) {
        return true
    }

    // Fallback: if AX marks it as main, consider it significant and include.
    // This helps when CGS space mapping is unreliable or empty for other-Spaces windows.
    if (try? axWindow.attribute(kAXMainAttribute, Bool.self)) == true {
        return true
    }

    return false
}
