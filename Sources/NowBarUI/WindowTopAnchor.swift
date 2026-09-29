import AppKit
import SwiftUI

/// Where a window's top edge should stay.
///
/// A menu bar window hangs from the menu bar: the system places it there when it opens. When the SwiftUI
/// content then changes size (Large Artwork to Compact and back), the window is resized around its bottom-left
/// corner, so a smaller window ends up floating below the menu bar and a larger one pokes up into it.
/// This remembers where the top edge was when the window appeared and says where to put it back afterwards.
///
/// Pure, so it is unit tested; `WindowTopAnchor` feeds it from the window.
struct TopEdgeAnchor {
    /// Drift of half a point or less isn't worth a correction.
    static let tolerance: CGFloat = 0.5

    /// The top edge (screen coordinates, y up) the system gave the window when it opened.
    /// nil while the window is hidden, or before it has been seen on screen.
    private(set) var top: CGFloat?

    /// The window is on screen at `frame`. The first sighting after `forget()` is where the system placed it;
    /// later ones (during a resize, say) leave the anchor alone.
    mutating func windowIsVisible(frame: NSRect) {
        if top == nil { top = frame.maxY }
    }

    /// The window was hidden or closed. The next time it opens the system places it afresh.
    mutating func forget() {
        top = nil
    }

    /// Where the window's top-left corner belongs now that it has been resized, or nil when its top edge is
    /// still where it was (or nothing is anchored).
    func topLeft(correcting frame: NSRect) -> NSPoint? {
        guard let top, abs(frame.maxY - top) > Self.tolerance else { return nil }
        return NSPoint(x: frame.minX, y: top)
    }
}

/// Keeps the MenuBarExtra window attached to the menu bar when its content changes size.
///
/// The window's top edge is remembered when it first appears on screen, and put back after every resize.
/// Losing key status doesn't forget it: the ⋯ menu can take key status while it is open, and that is exactly
/// when the layout changes. Only hiding, covering or closing the window forgets it, so the next open records
/// a fresh placement.
struct WindowTopAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        private var tokens: [NSObjectProtocol] = []
        private var anchor = TopEdgeAnchor()
        private var isCorrecting = false

        /// Never takes mouse events from the panel's content.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            anchor.forget()
            guard let window else { return }
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didResizeNotification,
                NSWindow.willCloseNotification,
            ]
            tokens = names.map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.windowDidChange(note.name)
                    }
                }
            }
            trackPlacement(of: window, occlusionChanged: false)
        }

        private func windowDidChange(_ name: Notification.Name) {
            guard let window else { return }
            if name == NSWindow.didResizeNotification {
                pinTopEdge(of: window)
            } else if name == NSWindow.willCloseNotification {
                anchor.forget()
            } else {
                trackPlacement(of: window, occlusionChanged: name == NSWindow.didChangeOcclusionStateNotification)
            }
        }

        /// The first time the window is seen on screen is where the system placed it. Once it is hidden (or,
        /// when the occlusion state just changed, covered up), the next open places it afresh.
        /// Key status plays no part.
        private func trackPlacement(of window: NSWindow, occlusionChanged: Bool) {
            let hidden = !window.isVisible || (occlusionChanged && !window.occlusionState.contains(.visible))
            if hidden {
                anchor.forget()
            } else {
                anchor.windowIsVisible(frame: window.frame)
            }
        }

        /// Puts the window's top edge back where the system placed it, keeping its left edge and its new size.
        private func pinTopEdge(of window: NSWindow) {
            guard !isCorrecting else { return }
            guard window.isVisible else {
                // Resized while hidden: there is nothing to keep in place, and any old placement is stale.
                anchor.forget()
                return
            }
            guard let target = anchor.topLeft(correcting: window.frame) else { return }
            isCorrecting = true
            defer { isCorrecting = false }
            window.setFrameTopLeftPoint(target)
        }

        private func removeObservers() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
