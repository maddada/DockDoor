import ApplicationServices.HIServices.AXRoleConstants
import Cocoa

// MARK: - Sysctl Utility for Process Inspection

/// Sysctl utility for querying process information (used for Android emulator detection)
/// Based on alt-tab-macos implementation
enum Sysctl {
    static func run(_ keys: [Int32]) -> String? {
        data(keys)?.withUnsafeBufferPointer { dataPointer -> String? in
            dataPointer.baseAddress.flatMap { String(validatingUTF8: $0) }
        }
    }

    private static func data(_ keys: [Int32]) -> [Int8]? {
        keys.withUnsafeBufferPointer { keysPointer in
            var requiredSize = 0
            let preFlightResult = Darwin.sysctl(
                UnsafeMutablePointer<Int32>(mutating: keysPointer.baseAddress),
                UInt32(keys.count),
                nil,
                &requiredSize,
                nil,
                0
            )
            if preFlightResult != 0 {
                return nil
            }
            let data = [Int8](repeating: 0, count: requiredSize)
            let result = data.withUnsafeBufferPointer { dataBuffer -> Int32 in
                return Darwin.sysctl(
                    UnsafeMutablePointer<Int32>(mutating: keysPointer.baseAddress),
                    UInt32(keys.count),
                    UnsafeMutableRawPointer(mutating: dataBuffer.baseAddress),
                    &requiredSize,
                    nil,
                    0
                )
            }
            if result != 0 {
                return nil
            }
            return data
        }
    }
}

// MARK: - Special Window Handlers

/// Handles special apps that use non-standard window subroles or rendering.
/// Based on alt-tab-macos implementation for maximum compatibility.
enum SpecialWindowHandlers {
    /// The normal window level (CGWindowLevelForKey(.normalWindow) returns 0)
    static let normalWindowLevel: Int32 = .init(CGWindowLevelForKey(.normalWindow))

    /// Floating window level
    static let floatingWindowLevel: Int32 = .init(CGWindowLevelForKey(.floatingWindow))

    // MARK: - Main Validation Function

    /// Determines if a window should be considered an "actual" window worth showing.
    /// This is more permissive than standard subrole checks, with special handling for apps
    /// that use non-standard window configurations (Steam, Android emulators, etc.)
    ///
    /// - Parameters:
    ///   - app: The running application owning the window
    ///   - wid: The CoreGraphics window ID
    ///   - level: The window level (from CGSGetWindowLevel)
    ///   - title: The window title (may be nil)
    ///   - subrole: The AX subrole (may be nil)
    ///   - role: The AX role (may be nil)
    ///   - size: The window size (may be nil)
    /// - Returns: true if the window should be included in the window list
    static func isActualWindow(
        app: NSRunningApplication,
        wid: CGWindowID,
        level: Int32,
        title: String?,
        subrole: String?,
        role: String?,
        size: CGSize?
    ) -> Bool {
        // Must have a valid window ID
        guard wid != 0 else {
            logWindowRejection(app: app, wid: wid, reason: "wid == 0")
            return false
        }

        // Must have a minimum size - filters out tiny popups/indicators
        // Finder's file copy dialogs are wide but < 100 height, so we use 50 for height
        guard let size, size.width > 100, size.height > 50 else {
            logWindowRejection(app: app, wid: wid, reason: "size too small: \(size?.debugDescription ?? "nil")")
            return false
        }

        let bundleId = app.bundleIdentifier

        // MARK: Special cases that bypass normal level check

        // These apps have legitimate windows that don't use level 0

        if isBooks(bundleId: bundleId) {
            logWindowAccepted(app: app, wid: wid, reason: "Books.app special case")
            return true
        }

        if isKeynote(bundleId: bundleId) {
            logWindowAccepted(app: app, wid: wid, reason: "Keynote special case")
            return true
        }

        if isPreview(bundleId: bundleId, subrole: subrole) {
            logWindowAccepted(app: app, wid: wid, reason: "Preview special case")
            return true
        }

        if isIINA(bundleId: bundleId) {
            logWindowAccepted(app: app, wid: wid, reason: "IINA special case")
            return true
        }

        if isOpenFLStudio(bundleId: bundleId, title: title) {
            logWindowAccepted(app: app, wid: wid, reason: "FL Studio special case")
            return true
        }

        if isCrossOverWindow(app: app, role: role, subrole: subrole, level: level) {
            logWindowAccepted(app: app, wid: wid, reason: "CrossOver/Wine special case")
            return true
        }

        if isAlwaysOnTopScrcpy(app: app, level: level, role: role, subrole: subrole) {
            logWindowAccepted(app: app, wid: wid, reason: "scrcpy always-on-top special case")
            return true
        }

        // MARK: Normal level check with special handlers

        // Most windows should be at normal level (0)

        guard level == normalWindowLevel else {
            logWindowRejection(app: app, wid: wid, reason: "level != normalWindow (\(level) vs \(normalWindowLevel))")
            return false
        }

        // Standard subroles - most apps use these
        if let subrole, [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole) {
            // Apply additional filters for problematic apps
            if !mustHaveIfJetbrainApp(bundleId: bundleId, title: title, subrole: subrole, size: size) {
                logWindowRejection(app: app, wid: wid, reason: "JetBrains filter rejected")
                return false
            }
            if !mustHaveIfSteam(bundleId: bundleId, title: title, role: role) {
                logWindowRejection(app: app, wid: wid, reason: "Steam filter rejected")
                return false
            }
            if !mustHaveIfFusion360(bundleId: bundleId, title: title) {
                logWindowRejection(app: app, wid: wid, reason: "Fusion360 filter rejected")
                return false
            }
            if !mustHaveIfColorSlurp(bundleId: bundleId, subrole: subrole) {
                logWindowRejection(app: app, wid: wid, reason: "ColorSlurp filter rejected")
                return false
            }
            logWindowAccepted(app: app, wid: wid, reason: "standard subrole: \(subrole)")
            return true
        }

        // MARK: Special app handlers for non-standard subroles

        // These apps use AXUnknown or other non-standard subroles

        if isOpenBoard(bundleId: bundleId) {
            logWindowAccepted(app: app, wid: wid, reason: "OpenBoard special case")
            return true
        }

        if isAdobeAudition(bundleId: bundleId, subrole: subrole) {
            logWindowAccepted(app: app, wid: wid, reason: "Adobe Audition special case")
            return true
        }

        if isAdobeAfterEffects(bundleId: bundleId, subrole: subrole) {
            logWindowAccepted(app: app, wid: wid, reason: "Adobe After Effects special case")
            return true
        }

        if isSteam(bundleId: bundleId, title: title, role: role) {
            logWindowAccepted(app: app, wid: wid, reason: "Steam special case (AXUnknown subrole)")
            return true
        }

        if isWorldOfWarcraft(bundleId: bundleId, role: role) {
            logWindowAccepted(app: app, wid: wid, reason: "World of Warcraft special case")
            return true
        }

        if isBattleNetBootstrapper(bundleId: bundleId, role: role) {
            logWindowAccepted(app: app, wid: wid, reason: "Battle.net Bootstrapper special case")
            return true
        }

        if isFirefox(bundleId: bundleId, role: role, size: size) {
            logWindowAccepted(app: app, wid: wid, reason: "Firefox special case")
            return true
        }

        if isVLCFullscreenVideo(bundleId: bundleId, role: role) {
            logWindowAccepted(app: app, wid: wid, reason: "VLC fullscreen special case")
            return true
        }

        if isSanGuoShaAirWD(bundleId: bundleId) {
            logWindowAccepted(app: app, wid: wid, reason: "SanGuoShaAirWD special case")
            return true
        }

        if isDVDFab(bundleId: bundleId) {
            logWindowAccepted(app: app, wid: wid, reason: "DVDFab special case")
            return true
        }

        if isDrBetotte(bundleId: bundleId) {
            logWindowAccepted(app: app, wid: wid, reason: "Dr. Betotte special case")
            return true
        }

        if isAndroidEmulator(app: app, title: title) {
            logWindowAccepted(app: app, wid: wid, reason: "Android emulator special case")
            return true
        }

        if isAutoCAD(bundleId: bundleId, subrole: subrole) {
            logWindowAccepted(app: app, wid: wid, reason: "AutoCAD special case")
            return true
        }

        // Additional special cases for apps mentioned in the bug report
        if isMinecraft(bundleId: bundleId, role: role) {
            logWindowAccepted(app: app, wid: wid, reason: "Minecraft special case")
            return true
        }

        if isCitrix(app: app, role: role) {
            logWindowAccepted(app: app, wid: wid, reason: "Citrix special case")
            return true
        }

        if isBlueStacks(bundleId: bundleId, role: role) {
            logWindowAccepted(app: app, wid: wid, reason: "BlueStacks special case")
            return true
        }

        logWindowRejection(app: app, wid: wid, reason: "no matching handler (subrole: \(subrole ?? "nil"), role: \(role ?? "nil"))")
        return false
    }

    /// Simplified check for brute-force window enumeration.
    /// More permissive than isValidAXWindowCandidate - allows windows with AXUnknown subrole
    /// if they belong to known special apps.
    static func isValidWindowForBruteForce(
        axWindow: AXUIElement,
        app: NSRunningApplication
    ) -> Bool {
        guard let role = try? axWindow.role(), role == kAXWindowRole else {
            return false
        }

        let subrole = try? axWindow.subrole()
        let bundleId = app.bundleIdentifier

        // Standard window subroles - always accept
        if let subrole, [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole) {
            return true
        }

        // Special apps that use AXUnknown or non-standard subroles
        if isSpecialAppWithNonStandardSubrole(app: app) {
            logBruteForceAccepted(app: app, reason: "special app with non-standard subrole")
            return true
        }

        return false
    }

    /// Returns true if this app is known to use non-standard window subroles
    static func isSpecialAppWithNonStandardSubrole(app: NSRunningApplication) -> Bool {
        let bundleId = app.bundleIdentifier

        // Steam - uses AXUnknown for all windows
        if bundleId == "com.valvesoftware.steam" {
            return true
        }

        // Battle.net
        if bundleId == "net.battle.bootstrapper" {
            return true
        }

        // World of Warcraft
        if bundleId == "com.blizzard.worldofwarcraft" {
            return true
        }

        // Android emulators (no bundle ID)
        if bundleId == nil, isAndroidEmulatorByExecutable(pid: app.processIdentifier) {
            return true
        }

        // CrossOver/Wine (no bundle ID, specific executable names)
        if bundleId == nil {
            let localizedName = app.localizedName ?? ""
            let executablePath = app.executableURL?.absoluteString ?? ""
            if localizedName == "wine64-preloader" || executablePath.contains("/winetemp-") {
                return true
            }
        }

        // VLC
        if bundleId?.hasPrefix("org.videolan.vlc") == true {
            return true
        }

        // Firefox
        if bundleId?.hasPrefix("org.mozilla.firefox") == true {
            return true
        }

        // OpenBoard (ported app)
        if bundleId == "org.oe-f.OpenBoard" {
            return true
        }

        // Adobe apps with floating windows
        if bundleId == "com.adobe.Audition" || bundleId == "com.adobe.AfterEffects" {
            return true
        }

        // BlueStacks
        if bundleId?.contains("BlueStacks") == true || bundleId?.contains("bluestacks") == true {
            return true
        }

        // Citrix
        if bundleId?.contains("citrix") == true || bundleId?.contains("Citrix") == true {
            return true
        }

        // Minecraft
        if bundleId?.contains("minecraft") == true || bundleId?.contains("Minecraft") == true {
            return true
        }

        // Emulators (check for common emulator bundle IDs)
        if isLikelyEmulator(bundleId: bundleId, localizedName: app.localizedName) {
            return true
        }

        return false
    }

    // MARK: - Individual App Handlers

    private static func isBooks(bundleId: String?) -> Bool {
        // Books.app has animations on window creation with subrole == AXUnknown or isOnNormalLevel == false
        bundleId == "com.apple.iBooksX"
    }

    private static func isKeynote(bundleId: String?) -> Bool {
        // Keynote has a fake fullscreen window when in presentation mode
        // It covers the screen with an AXUnknown window instead of using standard fullscreen mode
        bundleId == "com.apple.iWork.Keynote"
    }

    private static func isPreview(bundleId: String?, subrole: String?) -> Bool {
        // When opening multiple documents at once with Preview,
        // one window will have level == 1 for some reason
        bundleId == "com.apple.Preview" &&
            (subrole == nil || [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole!))
    }

    private static func isIINA(bundleId: String?) -> Bool {
        // IINA.app can have videos float (level == 2 instead of 0)
        bundleId == "com.colliderli.iina"
    }

    private static func isOpenFLStudio(bundleId: String?, title: String?) -> Bool {
        // FL Studio is a ported app which doesn't use standard macOS windows
        bundleId == "com.image-line.flstudio" && title != nil && !title!.isEmpty
    }

    private static func isCrossOverWindow(app: NSRunningApplication, role: String?, subrole: String?, level: Int32) -> Bool {
        // CrossOver/Wine apps have no bundle ID and use AXUnknown subrole
        app.bundleIdentifier == nil &&
            role == kAXWindowRole &&
            subrole == kAXUnknownSubrole &&
            level == normalWindowLevel &&
            (app.localizedName == "wine64-preloader" ||
                (app.executableURL?.absoluteString.contains("/winetemp-") ?? false))
    }

    private static func isAlwaysOnTopScrcpy(app: NSRunningApplication, level: Int32, role: String?, subrole: String?) -> Bool {
        // scrcpy presents as a floating window when "Always on top" is enabled
        app.localizedName == "scrcpy" &&
            level == floatingWindowLevel &&
            role == kAXWindowRole &&
            subrole == kAXStandardWindowSubrole
    }

    private static func isOpenBoard(bundleId: String?) -> Bool {
        // OpenBoard is a ported app which doesn't use standard macOS windows
        bundleId == "org.oe-f.OpenBoard"
    }

    private static func isAdobeAudition(bundleId: String?, subrole: String?) -> Bool {
        bundleId == "com.adobe.Audition" && subrole == kAXFloatingWindowSubrole
    }

    private static func isAdobeAfterEffects(bundleId: String?, subrole: String?) -> Bool {
        bundleId == "com.adobe.AfterEffects" && subrole == kAXFloatingWindowSubrole
    }

    private static func isSteam(bundleId: String?, title: String?, role: String?) -> Bool {
        // All Steam windows have subrole == AXUnknown
        // Some dropdown menus are not desirable; they have title == "" or role == nil
        bundleId == "com.valvesoftware.steam" &&
            title != nil && !title!.isEmpty &&
            role != nil
    }

    private static func mustHaveIfSteam(bundleId: String?, title: String?, role: String?) -> Bool {
        // Filter for Steam windows - must have title and role
        bundleId != "com.valvesoftware.steam" ||
            (title != nil && !title!.isEmpty && role != nil)
    }

    private static func isWorldOfWarcraft(bundleId: String?, role: String?) -> Bool {
        bundleId == "com.blizzard.worldofwarcraft" && role == kAXWindowRole
    }

    private static func isBattleNetBootstrapper(bundleId: String?, role: String?) -> Bool {
        // Battle.net bootstrapper windows have subrole == AXUnknown
        bundleId == "net.battle.bootstrapper" && role == kAXWindowRole
    }

    private static func isFirefox(bundleId: String?, role: String?, size: CGSize?) -> Bool {
        // Firefox fullscreen video has subrole == AXUnknown if fullscreen when base window is not fullscreen
        // Firefox tooltips are implemented as windows with subrole == AXUnknown
        // Filter by height to exclude tooltips
        (bundleId?.hasPrefix("org.mozilla.firefox") ?? false) &&
            role == kAXWindowRole &&
            (size?.height ?? 0) > 400
    }

    private static func isVLCFullscreenVideo(bundleId: String?, role: String?) -> Bool {
        // VLC fullscreen video has subrole == AXUnknown when fullscreen
        (bundleId?.hasPrefix("org.videolan.vlc") ?? false) && role == kAXWindowRole
    }

    private static func isSanGuoShaAirWD(bundleId: String?) -> Bool {
        bundleId == "SanGuoShaAirWD"
    }

    private static func isDVDFab(bundleId: String?) -> Bool {
        bundleId == "com.goland.dvdfab.macos"
    }

    private static func isDrBetotte(bundleId: String?) -> Bool {
        bundleId == "com.ssworks.drbetotte"
    }

    private static func isAndroidEmulator(app: NSRunningApplication, title: String?) -> Bool {
        // Android emulator small vertical menu is a "window" with empty title; we exclude it
        guard title != nil, !title!.isEmpty else { return false }
        return isAndroidEmulatorByExecutable(pid: app.processIdentifier)
    }

    private static func isAndroidEmulatorByExecutable(pid: pid_t) -> Bool {
        // NSRunningApplication provides no way to identify the emulator
        // We pattern match on its KERN_PROCARGS
        if let executablePath = Sysctl.run([CTL_KERN, KERN_PROCARGS, pid]) {
            // Example path: ~/Library/Android/sdk/emulator/qemu/darwin-x86_64/qemu-system-x86_64
            return executablePath.range(of: "qemu-system[^/]*$", options: .regularExpression) != nil
        }
        return false
    }

    private static func isAutoCAD(bundleId: String?, subrole: String?) -> Bool {
        // AutoCAD uses the undocumented "AXDocumentWindow" subrole
        (bundleId?.hasPrefix("com.autodesk.AutoCAD") ?? false) && subrole == kAXDocumentWindowSubrole
    }

    private static func mustHaveIfJetbrainApp(bundleId: String?, title: String?, subrole: String?, size: CGSize) -> Bool {
        // JetBrains apps sometimes generate non-windows that pass all checks
        // They have no title, so we filter them out based on that
        let isJetBrains = bundleId?.range(of: "^com\\.(jetbrains\\.|google\\.android\\.studio).*?$", options: .regularExpression) != nil
        return !isJetBrains || (
            (subrole == kAXStandardWindowSubrole || (title != nil && !title!.isEmpty)) &&
                size.width > 100 && size.height > 100
        )
    }

    private static func mustHaveIfFusion360(bundleId: String?, title: String?) -> Bool {
        // Filter out Autodesk Fusion side panels "Browser" and "Comments" with subrole AXDialog but no title
        bundleId != "com.autodesk.fusion360" || (title != nil && !title!.isEmpty)
    }

    private static func mustHaveIfColorSlurp(bundleId: String?, subrole: String?) -> Bool {
        bundleId != "com.IdeaPunch.ColorSlurp" || subrole == kAXStandardWindowSubrole
    }

    // MARK: Additional handlers for apps mentioned in bug report

    private static func isMinecraft(bundleId: String?, role: String?) -> Bool {
        // Minecraft may use custom rendering with non-standard subroles
        let isMinecraft = bundleId?.lowercased().contains("minecraft") ?? false
        return isMinecraft && role == kAXWindowRole
    }

    private static func isCitrix(app: NSRunningApplication, role: String?) -> Bool {
        // Citrix/Remote desktop apps use virtualized windows
        let bundleId = app.bundleIdentifier?.lowercased() ?? ""
        let localizedName = app.localizedName?.lowercased() ?? ""
        let isCitrix = bundleId.contains("citrix") || localizedName.contains("citrix") ||
            bundleId.contains("receiver") || localizedName.contains("workspace")
        return isCitrix && role == kAXWindowRole
    }

    private static func isBlueStacks(bundleId: String?, role: String?) -> Bool {
        // BlueStacks Android emulator
        let isBlueStacks = bundleId?.lowercased().contains("bluestacks") ?? false
        return isBlueStacks && role == kAXWindowRole
    }

    private static func isLikelyEmulator(bundleId: String?, localizedName: String?) -> Bool {
        let emulatorKeywords = ["emulator", "qemu", "virtualbox", "vmware", "parallels", "mumu", "nox", "ldplayer", "genymotion"]
        let bundleLower = bundleId?.lowercased() ?? ""
        let nameLower = localizedName?.lowercased() ?? ""

        for keyword in emulatorKeywords {
            if bundleLower.contains(keyword) || nameLower.contains(keyword) {
                return true
            }
        }
        return false
    }

    // MARK: - Logging

    private static func logWindowRejection(app: NSRunningApplication, wid: CGWindowID, reason: String) {
        #if DEBUG
            print("[SpecialWindowHandlers] REJECTED window \(wid) from \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "no bundle")): \(reason)")
        #endif
    }

    private static func logWindowAccepted(app: NSRunningApplication, wid: CGWindowID, reason: String) {
        #if DEBUG
            print("[SpecialWindowHandlers] ACCEPTED window \(wid) from \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "no bundle")): \(reason)")
        #endif
    }

    private static func logBruteForceAccepted(app: NSRunningApplication, reason: String) {
        #if DEBUG
            print("[SpecialWindowHandlers] BRUTE-FORCE accepted window from \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "no bundle")): \(reason)")
        #endif
    }
}

// Add the missing AXDocumentWindowSubrole constant
let kAXDocumentWindowSubrole = "AXDocumentWindow"
let kAXFloatingWindowSubrole = "AXFloatingWindow"
let kAXUnknownSubrole = "AXUnknown"
