import AppKit
import Testing
import NowBarCore
@testable import NowBarServices

/// Feeds synthetic NX_SYSDEFINED events through the same path the event tap callback uses: NSEvent decoding,
/// the press/repeat/release gate and the handler. No event tap is installed and nothing is posted.
@MainActor @Suite struct MediaKeyTapPipelineTests {
    func event(
        _ keyCode: Int,
        state: Int = 0xA,
        isRepeat: Bool = false,
        subtype: Int16 = 8,
        type: NSEvent.EventType = .systemDefined
    ) -> CGEvent {
        let data1 = (keyCode << 16) | (state << 8) | (isRepeat ? 1 : 0)
        let event = NSEvent.otherEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, subtype: subtype, data1: data1, data2: -1)
        return event!.cgEvent!
    }

    func makeTap(handler: ((MediaKey) -> Bool)?) -> MediaKeyTap {
        let tap = MediaKeyTap()
        tap.handler = handler
        return tap
    }

    @Test func consumesAPressAndItsRepeatsAndRelease() {
        var asked: [MediaKey] = []
        let tap = makeTap { asked.append($0); return true }

        #expect(tap.shouldSwallow(event(16)))
        #expect(tap.shouldSwallow(event(16, isRepeat: true)))
        #expect(tap.shouldSwallow(event(16, state: 0xB)))
        #expect(asked == [.playPause])
    }

    @Test func passesEverythingThroughWhenTheHandlerDeclines() {
        var asked: [MediaKey] = []
        let tap = makeTap { asked.append($0); return false }

        #expect(!tap.shouldSwallow(event(17)))
        #expect(!tap.shouldSwallow(event(17, isRepeat: true)))
        #expect(!tap.shouldSwallow(event(17, state: 0xB)))
        #expect(asked == [.next])
    }

    @Test func mapsEveryKeyCodeToItsKey() {
        var asked: [MediaKey] = []
        let tap = makeTap { asked.append($0); return true }

        for code in [16, 17, 18, 19, 20, 7, 0, 1] {
            _ = tap.shouldSwallow(event(code))
            _ = tap.shouldSwallow(event(code, state: 0xB))
        }
        #expect(asked == [.playPause, .next, .previous, .next, .previous, .mute, .volumeUp, .volumeDown])
    }

    @Test func leavesOtherKeysAlone() {
        var asked = 0
        let tap = makeTap { _ in asked += 1; return true }

        // Brightness up, eject and keyboard backlight.
        for code in [2, 14, 21] {
            #expect(!tap.shouldSwallow(event(code)))
            #expect(!tap.shouldSwallow(event(code, state: 0xB)))
        }
        #expect(asked == 0)
    }

    @Test func leavesOtherSubtypesAndEventTypesAlone() {
        var asked = 0
        let tap = makeTap { _ in asked += 1; return true }

        #expect(!tap.shouldSwallow(event(16, subtype: 7)))
        #expect(!tap.shouldSwallow(event(16, subtype: 0)))
        #expect(!tap.shouldSwallow(event(16, type: .applicationDefined)))
        #expect(asked == 0)
    }

    @Test func withoutAHandlerNothingIsSwallowed() {
        let tap = makeTap(handler: nil)
        #expect(!tap.shouldSwallow(event(16)))
        #expect(!tap.shouldSwallow(event(16, state: 0xB)))
    }

    @Test func aDeclinedPressDoesNotSwallowItsRelease() {
        var answers = [true, false]
        let tap = makeTap { _ in answers.removeFirst() }

        #expect(tap.shouldSwallow(event(16)))
        #expect(tap.shouldSwallow(event(16, state: 0xB)))
        #expect(!tap.shouldSwallow(event(16)))
        #expect(!tap.shouldSwallow(event(16, state: 0xB)))
    }

    @Test func aNewTapIsDisabled() {
        #expect(MediaKeyTap().isEnabled == false)
    }
}
