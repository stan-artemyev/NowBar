import AppKit
import SwiftUI
import Testing
@testable import NowBarUI

/// Where the window goes when the panel changes size (`WindowFit`, a pure rule).
@Suite("Window fit")
struct WindowFitTests {
    /// A Large Artwork panel window: 300 x 504, its top edge at y = 904, just under the menu bar.
    let large = NSRect(x: 100, y: 400, width: 300, height: 504)
    /// The same window after the switch to Compact (236 pt tall): same top edge, same left edge.
    let compact = NSRect(x: 100, y: 668, width: 300, height: 236)

    /// The frame that fits `frame`'s window to `size`. `chrome` is the height its frame has beyond its content
    /// area (a title bar); the menu bar panel has none.
    func fit(_ frame: NSRect, to size: NSSize, chrome: CGFloat = 0) -> NSRect? {
        WindowFit.frame(
            keepingTopLeftOf: frame,
            currentContent: NSSize(width: frame.width, height: frame.height - chrome),
            fitting: size,
            frameSize: { NSSize(width: $0.width, height: $0.height + chrome) }
        )
    }

    @Test func shrinksWhenTheContentGetsShorter() {
        // Large to Compact. AppKit's own resize would keep the bottom-left corner and float the window below the bar.
        #expect(fit(large, to: compact.size) == compact)
    }

    @Test func growsWhenTheContentGetsTaller() {
        // Compact to Large. AppKit's own resize would keep the bottom-left corner and push the window into the bar.
        #expect(fit(compact, to: large.size) == large)
    }

    @Test func keepsTheTopAndLeftEdgesWhereTheyAre() throws {
        // Wherever the status item put the window, whichever way it changes size.
        let placed = NSRect(x: 1234.5, y: 601.25, width: 300, height: 504)   // top edge at 1105.25
        for height in [236.0, 700.0, 100.5, 504.75] {
            let frame = try #require(fit(placed, to: NSSize(width: 300, height: height)))
            #expect(frame.maxY == placed.maxY, "top edge, at a height of \(height)")
            #expect(frame.minX == placed.minX, "left edge, at a height of \(height)")
            #expect(frame.size == NSSize(width: 300, height: height))
        }
    }

    @Test func leavesAWindowWhoseContentAlreadyFitsAlone() {
        #expect(fit(large, to: large.size) == nil)
        #expect(fit(compact, to: compact.size) == nil)
    }

    @Test func halfAPointOfDifferenceIsNotWorthAResize() {
        #expect(fit(large, to: NSSize(width: 300, height: 504.5)) == nil)
        #expect(fit(large, to: NSSize(width: 300, height: 503.5)) == nil)
        #expect(fit(large, to: NSSize(width: 300.5, height: 504)) == nil)
        #expect(fit(large, to: NSSize(width: 299.5, height: 504)) == nil)

        // More is.
        #expect(fit(large, to: NSSize(width: 300, height: 504.75)) != nil)
        #expect(fit(large, to: NSSize(width: 300, height: 503.25)) != nil)
        #expect(fit(large, to: NSSize(width: 300.75, height: 504)) != nil)
        #expect(fit(large, to: NSSize(width: 299.25, height: 504)) != nil)
    }

    @Test func aFittedWindowNeedsNoFurtherFit() throws {
        let shrunk = try #require(fit(large, to: compact.size))
        #expect(fit(shrunk, to: compact.size) == nil)

        // And back again, to exactly where it began.
        #expect(fit(shrunk, to: large.size) == large)
    }

    @Test func followsAChangeOfWidthToo() {
        // It grows to the right: the left edge is the one that stays.
        #expect(fit(large, to: NSSize(width: 320, height: 504)) == NSRect(x: 100, y: 400, width: 320, height: 504))
    }

    @Test func addsTheWindowsChromeToTheFrameButNotToTheComparison() throws {
        // A window with a 28 pt title bar: its content area is 28 pt shorter than its frame.
        let titled = NSRect(x: 100, y: 372, width: 300, height: 532)   // 300 x 504 of content, top edge at 904
        #expect(fit(titled, to: NSSize(width: 300, height: 504), chrome: 28) == nil)   // the content already fits

        let frame = try #require(fit(titled, to: compact.size, chrome: 28))
        #expect(frame == NSRect(x: 100, y: 640, width: 300, height: 264))   // 236 + 28 tall, same top edge
    }

    @MainActor
    @Test func readsTheWindowsContentAreaNotItsFrame() throws {
        _ = NSApplication.shared
        // A window with a title bar, unlike the panel's: its frame is taller than its content area.
        let window = NSWindow(contentRect: large, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(window.frame.height > large.height)
        #expect(window.contentRect(forFrameRect: window.frame).size == large.size)

        // The content area already is this size, whatever the frame says.
        #expect(WindowFit.frame(fitting: large.size, in: window) == nil)

        let frame = try #require(WindowFit.frame(fitting: compact.size, in: window))
        #expect(frame.maxY == window.frame.maxY)     // the same top edge: the title bar's, not the content's
        #expect(frame.minX == window.frame.minX)
        #expect(window.contentRect(forFrameRect: frame).size == compact.size)   // the frame carries the title bar
    }

    @Test func ignoresASizeThatIsNotUsable() {
        // The zero SwiftUI reports before it has measured anything, and values that can't be a size.
        #expect(fit(large, to: .zero) == nil)
        #expect(fit(large, to: NSSize(width: 300, height: 0)) == nil)
        #expect(fit(large, to: NSSize(width: 0, height: 236)) == nil)
        #expect(fit(large, to: NSSize(width: 300, height: -236)) == nil)
        #expect(fit(large, to: NSSize(width: 300, height: CGFloat.nan)) == nil)
        #expect(fit(large, to: NSSize(width: CGFloat.infinity, height: 236)) == nil)
    }
}

/// A stand-in for the menu bar panel's window: never on screen, but it says it is visible (unless told
/// otherwise) and records what it is asked to do.
@MainActor
final class SpyPanelWindow: NSWindow {
    var reportsVisible = true
    private(set) var frameChanges: [NSRect] = []
    private(set) var shadowInvalidations = 0

    override var isVisible: Bool { reportsVisible }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        frameChanges.append(frameRect)
        super.setFrame(frameRect, display: flag)
    }

    override func invalidateShadow() {
        shadowInvalidations += 1
        super.invalidateShadow()
    }
}

/// The next turn of the main queue, run by hand.
@MainActor
final class ManualQueue {
    private(set) var pending: [() -> Void] = []

    func enqueue(_ work: @escaping () -> Void) {
        pending.append(work)
    }

    /// Runs what is queued, as the main queue would on its next turn.
    func runPending() {
        let batch = pending
        pending = []
        for work in batch { work() }
    }
}

/// The AppKit half: `WindowFitter.FitView` applies the rule to a window, on the next turn of the main queue and
/// never inside the update that told it the panel's size.
@MainActor
@Suite("Window fitter")
struct WindowFitterTests {
    let large = NSRect(x: 100, y: 400, width: 300, height: 504)
    let compact = NSRect(x: 100, y: 668, width: 300, height: 236)

    /// A window shaped like the panel's, with the fitter in its content. With a `queue` the fitter's next turn
    /// is that queue, and joining the window has already asked for a fit: it is what waits in the queue.
    func makeWindow(
        _ frame: NSRect,
        queue: ManualQueue? = nil,
        styleMask: NSWindow.StyleMask = [.borderless]
    ) -> (window: SpyPanelWindow, fitter: WindowFitter.FitView) {
        _ = NSApplication.shared
        let window = SpyPanelWindow(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = content
        let fitter = WindowFitter.FitView(frame: content.bounds)
        if let queue { fitter.enqueue = queue.enqueue }
        content.addSubview(fitter)
        return (window, fitter)
    }

    // MARK: On the real main queue

    @Test func fitsOnTheNextTurnOfTheMainQueue() async {
        let (window, fitter) = makeWindow(large)

        fitter.contentSize = compact.size   // what `updateNSView` does in the middle of an update
        #expect(window.frame == large)      // nothing has moved yet
        #expect(window.frameChanges.isEmpty)

        #expect(await eventually { window.frame == compact })
        #expect(window.frameChanges == [compact])
        #expect(window.shadowInvalidations == 1)   // the old shape's shadow doesn't stay behind
    }

    // MARK: Step by step

    @Test func joiningAWindowAsksForAFit() {
        let queue = ManualQueue()
        let (window, _) = makeWindow(large, queue: queue)
        #expect(queue.pending.count == 1)
        #expect(window.frameChanges.isEmpty)   // asking is all it does
    }

    @Test func aNewSizeOnlyAsksForAFit() {
        let queue = ManualQueue()
        let (window, fitter) = makeWindow(large, queue: queue)
        queue.runPending()   // joining the window: the size isn't known yet, so nothing to do

        fitter.contentSize = compact.size   // the update
        #expect(queue.pending.count == 1)
        #expect(window.frameChanges.isEmpty)   // the window is left alone until the next turn

        queue.runPending()
        #expect(window.frame == compact)
        #expect(window.frameChanges == [compact])
        #expect(window.shadowInvalidations == 1)
    }

    @Test func manyRequestsBeforeTheNextTurnMakeOneFit() {
        let queue = ManualQueue()
        let (window, fitter) = makeWindow(large, queue: queue)
        queue.runPending()

        for height in [400.0, 300.0, 236.0] {
            fitter.contentSize = CGSize(width: 300, height: height)
            fitter.scheduleFit()
        }
        #expect(queue.pending.count == 1)

        queue.runPending()
        #expect(window.frameChanges == [compact])   // the latest size, once

        // Once it has run, the next request is a new one.
        fitter.contentSize = large.size
        #expect(queue.pending.count == 1)
    }

    @Test func shrinksAndGrowsAroundTheTopEdge() {
        let queue = ManualQueue()
        let (window, fitter) = makeWindow(large, queue: queue)
        queue.runPending()

        fitter.contentSize = compact.size
        queue.runPending()
        #expect(window.frame == compact)

        fitter.contentSize = large.size
        queue.runPending()
        #expect(window.frame == large)
        #expect(window.frameChanges == [compact, large])
        #expect(window.shadowInvalidations == 2)
    }

    @Test func doesNothingWhenTheWindowAlreadyFits() {
        let queue = ManualQueue()
        let (window, fitter) = makeWindow(large, queue: queue)

        fitter.contentSize = large.size
        queue.runPending()
        #expect(window.frameChanges.isEmpty)
        #expect(window.shadowInvalidations == 0)
    }

    @Test func doesNothingBeforeThePanelHasBeenMeasured() {
        let queue = ManualQueue()
        let (window, _) = makeWindow(large, queue: queue)

        queue.runPending()   // the size is still zero
        #expect(window.frameChanges.isEmpty)
    }

    @Test func aSameSizeAgainAsksForNothing() {
        let queue = ManualQueue()
        let (window, fitter) = makeWindow(large, queue: queue)
        queue.runPending()

        fitter.contentSize = compact.size
        queue.runPending()
        fitter.contentSize = compact.size   // SwiftUI updating again without a new size
        #expect(queue.pending.isEmpty)
        #expect(window.frameChanges == [compact])   // the one fit, for the first request
    }

    @Test(arguments: [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification])
    func leavesAHiddenWindowAloneAndFitsItOnceItIsVisible(_ event: Notification.Name) async {
        let queue = ManualQueue()
        let (window, fitter) = makeWindow(large, queue: queue)
        window.reportsVisible = false

        fitter.contentSize = compact.size
        queue.runPending()
        #expect(window.frameChanges.isEmpty)   // hidden: nothing to resize
        #expect(queue.pending.isEmpty)

        window.reportsVisible = true
        NotificationCenter.default.post(name: event, object: window)
        #expect(await eventually { queue.pending.count == 1 })   // the window is visible: a fit is asked for
        queue.runPending()
        #expect(window.frame == compact)
        #expect(window.frameChanges == [compact])
    }

    @Test func otherWindowsAreNoneOfItsBusiness() async {
        let queue = ManualQueue()
        let (window, _) = makeWindow(large, queue: queue)
        let (other, _) = makeWindow(large)
        queue.runPending()   // joining the window

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(queue.pending.isEmpty)   // another window becoming key asks for nothing
        #expect(window.frameChanges.isEmpty)
    }

    @Test func neverTakesMouseEvents() {
        let (window, fitter) = makeWindow(large)
        withExtendedLifetime(window) {
            #expect(fitter.hitTest(NSPoint(x: 10, y: 10)) == nil)
        }
    }
}

/// The whole path, with the real panel: a layout switch changes what SwiftUI measures, and the window follows.
@MainActor
@Suite("Panel window")
struct PanelWindowTests {
    /// The panel's ideal size for the store's current layout: what the window gets when the system sizes it.
    func idealSize(of store: PlayerStore) -> NSSize {
        NSHostingView(rootView: PlayerPanel(store: store)).fittingSize
    }

    @Test func theWindowFollowsTheLayoutSwitchInBothDirections() async {
        _ = NSApplication.shared
        let harness = Harness()
        harness.startAndPush(Fixture.running())
        let largeSize = idealSize(of: harness.store)
        harness.store.layout = .compact
        let compactSize = idealSize(of: harness.store)
        harness.store.layout = .large
        #expect(largeSize.width == 300)
        #expect(compactSize.width == 300)
        #expect(compactSize.height < largeSize.height)

        // The MenuBarExtra window doesn't follow its content once it is open; a hosting view that isn't asked
        // to size its window either is the same.
        let large = NSRect(origin: NSPoint(x: 100, y: 400), size: largeSize)
        let compact = NSRect(x: large.minX, y: large.maxY - compactSize.height, width: 300, height: compactSize.height)
        let window = SpyPanelWindow(contentRect: large, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PlayerPanel(store: harness.store))
        host.sizingOptions = []
        window.contentView = host

        // Compact: the window shrinks and keeps hanging from the same top edge.
        harness.store.layout = .compact
        #expect(await eventually { host.layoutSubtreeIfNeeded(); return window.frame == compact })

        // Large again: the window grows back to exactly where it began.
        harness.store.layout = .large
        #expect(await eventually { host.layoutSubtreeIfNeeded(); return window.frame == large })

        #expect(window.frameChanges == [compact, large])   // nothing else moved it, and it never jittered
        #expect(window.shadowInvalidations == 2)
    }
}
