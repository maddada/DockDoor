import AppKit
import Defaults
import SwiftUI

final class WindowHighlightCoordinator {
    static let shared = WindowHighlightCoordinator()

    private var highlightPanel: NSPanel?
    private var fadeOutWorkItem: DispatchWorkItem?
    private var showWorkItem: DispatchWorkItem?

    private let borderWidth: CGFloat = 3.0
    private let visibleDuration: TimeInterval = 0.3
    private let showDelay: TimeInterval = 0.1

    private init() {}

    /// Shows a highlight border around the specified window frame
    /// - Parameters:
    ///   - frame: The frame of the window to highlight (in screen coordinates)
    ///   - screen: The screen containing the window
    func showHighlight(around frame: CGRect, on screen: NSScreen) {
        guard Defaults[.highlightActiveWindow] else { return }

        // Cancel any pending show or fade out
        showWorkItem?.cancel()
        showWorkItem = nil
        fadeOutWorkItem?.cancel()
        fadeOutWorkItem = nil

        // Hide existing panel if any
        highlightPanel?.orderOut(nil)
        highlightPanel = nil

        // Schedule the highlight to show after delay
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            // Create the highlight panel
            let panel = createHighlightPanel(for: frame, on: screen)
            highlightPanel = panel

            // Show immediately
            panel.orderFrontRegardless()

            // Schedule hide after visible duration
            let hideWorkItem = DispatchWorkItem { [weak self] in
                self?.hideHighlight()
            }
            fadeOutWorkItem = hideWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: hideWorkItem)
        }

        showWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: workItem)
    }

    /// Shows a highlight around a WindowInfo object
    func showHighlight(for windowInfo: WindowInfo) {
        guard Defaults[.highlightActiveWindow] else { return }

        // Get the window frame from the WindowInfo
        let windowFrame = windowInfo.frame

        // Convert from CGWindow coordinates (origin at top-left) to NSScreen coordinates (origin at bottom-left)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) ?? NSScreen.main else {
            return
        }

        // CGWindow uses top-left origin, NSWindow uses bottom-left origin
        // We need to flip the y coordinate
        let screenFrame = screen.frame
        let flippedY = screenFrame.maxY - windowFrame.maxY

        let convertedFrame = CGRect(
            x: windowFrame.origin.x,
            y: flippedY,
            width: windowFrame.width,
            height: windowFrame.height
        )

        showHighlight(around: convertedFrame, on: screen)
    }

    private func hideHighlight() {
        highlightPanel?.orderOut(nil)
        highlightPanel = nil
    }

    private func createHighlightPanel(for frame: CGRect, on screen: NSScreen) -> NSPanel {
        // Expand frame slightly to account for border width
        let expandedFrame = frame.insetBy(dx: -borderWidth, dy: -borderWidth)

        let panel = NSPanel(
            contentRect: expandedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Create the border view
        let borderView = WindowHighlightBorderView(
            frame: NSRect(origin: .zero, size: expandedFrame.size),
            borderWidth: borderWidth
        )
        panel.contentView = borderView

        return panel
    }
}

// MARK: - Border View

private class WindowHighlightBorderView: NSView {
    private let borderWidth: CGFloat
    private let cornerRadius: CGFloat = 10.0

    init(frame: NSRect, borderWidth: CGFloat) {
        self.borderWidth = borderWidth
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let highlightColor = if Defaults[.highlightActiveWindowUseCustomColor] {
            NSColor(Defaults[.highlightActiveWindowColor])
        } else {
            NSColor.controlAccentColor
        }

        // Draw the border
        let borderRect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: cornerRadius, yRadius: cornerRadius)
        borderPath.lineWidth = borderWidth

        highlightColor.setStroke()
        borderPath.stroke()
    }
}
