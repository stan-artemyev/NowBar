import AppKit
import Testing
@testable import NowBarUI

/// The AppKit half (`WindowTopAnchor`, which watches the window) can't run here; the rule it applies can.
@Suite("Window top anchor")
struct WindowTopAnchorTests {
    /// A 500 pt tall window whose top edge is at y = 900: where the system placed it, under the menu bar.
    let placed = NSRect(x: 100, y: 400, width: 300, height: 500)

    @Test func hasNoAnchorUntilTheWindowIsSeen() {
        let anchor = TopEdgeAnchor()
        #expect(anchor.top == nil)
        #expect(anchor.topLeft(correcting: NSRect(x: 100, y: 400, width: 300, height: 300)) == nil)
    }

    @Test func remembersWhereTheSystemPlacedTheWindow() {
        var anchor = TopEdgeAnchor()
        anchor.windowIsVisible(frame: placed)
        #expect(anchor.top == 900)
    }

    @Test func keepsTheFirstPlacementWhileTheWindowStaysOnScreen() {
        var anchor = TopEdgeAnchor()
        anchor.windowIsVisible(frame: placed)
        anchor.windowIsVisible(frame: NSRect(x: 100, y: 400, width: 300, height: 300))   // shrunk: its top fell to 700
        #expect(anchor.top == 900)
    }

    @Test func putsTheTopBackWhenTheWindowShrinks() {
        // Compact is 300 pt tall. AppKit kept the bottom-left corner at (100, 400), so the top fell from 900 to 700.
        var anchor = TopEdgeAnchor()
        anchor.windowIsVisible(frame: placed)
        let shrunk = NSRect(x: 100, y: 400, width: 300, height: 300)
        #expect(anchor.topLeft(correcting: shrunk) == NSPoint(x: 100, y: 900))
    }

    @Test func putsTheTopBackWhenTheWindowGrows() {
        // Back to Large Artwork: the bottom-left corner stayed, so the top rose from 900 into the menu bar.
        var anchor = TopEdgeAnchor()
        anchor.windowIsVisible(frame: NSRect(x: 100, y: 600, width: 300, height: 300))
        let grown = NSRect(x: 100, y: 600, width: 300, height: 500)
        #expect(anchor.topLeft(correcting: grown) == NSPoint(x: 100, y: 900))
    }

    @Test func onlyTheTopIsPinned() {
        // The window hangs under the status item wherever that is: its left edge stays where the system put it.
        var anchor = TopEdgeAnchor()
        anchor.windowIsVisible(frame: NSRect(x: 1234.5, y: 400, width: 300, height: 500))
        let shrunk = NSRect(x: 1234.5, y: 400, width: 300, height: 300)
        #expect(anchor.topLeft(correcting: shrunk) == NSPoint(x: 1234.5, y: 900))
    }

    @Test func aCorrectedWindowNeedsNoFurtherCorrection() throws {
        var anchor = TopEdgeAnchor()
        anchor.windowIsVisible(frame: placed)
        let shrunk = NSRect(x: 100, y: 400, width: 300, height: 300)
        let target = try #require(anchor.topLeft(correcting: shrunk))

        // What `setFrameTopLeftPoint` does: same size, top-left corner at the target.
        let corrected = NSRect(x: target.x, y: target.y - shrunk.height, width: shrunk.width, height: shrunk.height)
        #expect(corrected.maxY == 900)
        #expect(anchor.topLeft(correcting: corrected) == nil)
    }

    @Test func leavesAWindowWhoseTopIsStillInPlaceAlone() {
        var anchor = TopEdgeAnchor()
        anchor.windowIsVisible(frame: placed)
        #expect(anchor.topLeft(correcting: placed) == nil)
        // Half a point of drift isn't worth a move; more is.
        #expect(anchor.topLeft(correcting: placed.offsetBy(dx: 0, dy: 0.5)) == nil)
        #expect(anchor.topLeft(correcting: placed.offsetBy(dx: 0, dy: -0.5)) == nil)
        #expect(anchor.topLeft(correcting: placed.offsetBy(dx: 0, dy: 0.6)) != nil)
        #expect(anchor.topLeft(correcting: placed.offsetBy(dx: 0, dy: -0.6)) != nil)
    }

    @Test func forgetsThePlacementWhenTheWindowIsHidden() {
        var anchor = TopEdgeAnchor()
        anchor.windowIsVisible(frame: placed)
        anchor.forget()
        #expect(anchor.top == nil)
        #expect(anchor.topLeft(correcting: NSRect(x: 100, y: 400, width: 300, height: 300)) == nil)   // nothing to enforce while hidden

        // The next open records a fresh placement, wherever the system put it this time.
        anchor.windowIsVisible(frame: NSRect(x: 500, y: 300, width: 300, height: 500))
        #expect(anchor.top == 800)
    }
}
