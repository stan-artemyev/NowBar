import Testing
import NowBarCore
@testable import NowBarServices

@Suite struct MediaKeyDecodingTests {
    static let down = 0xA
    static let up = 0xB

    /// `data1` as macOS builds it: key code in the top 16 bits, key state and repeat flag in the bottom 16.
    func data1(_ keyCode: Int, state: Int = MediaKeyDecodingTests.down, isRepeat: Bool = false) -> Int {
        (keyCode << 16) | (state << 8) | (isRepeat ? 1 : 0)
    }

    /// NX_KEYTYPE_* codes and the key they map to.
    let mapping: [(code: Int, key: MediaKey)] = [
        (16, .playPause), // PLAY
        (17, .next),      // NEXT
        (19, .next),      // FAST
        (18, .previous),  // PREVIOUS
        (20, .previous),  // REWIND
        (7, .mute),       // MUTE
        (0, .volumeUp),   // SOUND_UP
        (1, .volumeDown), // SOUND_DOWN
    ]

    @Test func decodesEachKeyDown() {
        for (code, key) in mapping {
            #expect(MediaKeyDecoder.decode(subtype: 8, data1: data1(code)) == MediaKeyEvent(key: key, isDown: true, isRepeat: false),
                    "key code \(code)")
        }
    }

    @Test func decodesEachKeyUp() {
        for (code, key) in mapping {
            #expect(MediaKeyDecoder.decode(subtype: 8, data1: data1(code, state: Self.up)) == MediaKeyEvent(key: key, isDown: false, isRepeat: false),
                    "key code \(code)")
        }
    }

    @Test func decodesEachRepeat() {
        for (code, key) in mapping {
            #expect(MediaKeyDecoder.decode(subtype: 8, data1: data1(code, isRepeat: true)) == MediaKeyEvent(key: key, isDown: true, isRepeat: true),
                    "key code \(code)")
        }
    }

    @Test func decodesValuesSeenFromRealKeyboards() {
        // F8 (play/pause): key down, key up, and an auto-repeat while held.
        #expect(MediaKeyDecoder.decode(subtype: 8, data1: 0x0010_0A00) == MediaKeyEvent(key: .playPause, isDown: true, isRepeat: false))
        #expect(MediaKeyDecoder.decode(subtype: 8, data1: 0x0010_0B00) == MediaKeyEvent(key: .playPause, isDown: false, isRepeat: false))
        #expect(MediaKeyDecoder.decode(subtype: 8, data1: 0x0010_0A01) == MediaKeyEvent(key: .playPause, isDown: true, isRepeat: true))
        // Volume up, key down.
        #expect(MediaKeyDecoder.decode(subtype: 8, data1: 0x0000_0A00) == MediaKeyEvent(key: .volumeUp, isDown: true, isRepeat: false))
    }

    @Test func everyMediaKeyIsReachable() {
        #expect(Set(mapping.map(\.key)) == Set(MediaKey.allCases))
    }

    @Test func statesOtherThanDownAreNotDown() {
        for state in [0x0, 0x1, 0x9, 0xC, 0xFF] {
            #expect(MediaKeyDecoder.decode(subtype: 8, data1: data1(16, state: state))?.isDown == false, "state \(state)")
        }
    }

    @Test func ignoresKeysThatAreNotMediaKeys() {
        // Brightness up/down, caps lock, eject, keyboard backlight up/down/toggle, and codes past the known range.
        for code in [2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15, 21, 22, 23, 24, 100, 0xFFFF] {
            #expect(MediaKeyDecoder.decode(subtype: 8, data1: data1(code)) == nil, "key code \(code)")
            #expect(MediaKeyDecoder.decode(subtype: 8, data1: data1(code, state: Self.up)) == nil, "key code \(code) up")
        }
    }

    @Test func ignoresOtherSubtypes() {
        for subtype: Int16 in [0, 1, 2, 3, 7, 9, 10, 16, -1, .max] {
            #expect(MediaKeyDecoder.decode(subtype: subtype, data1: data1(16)) == nil, "subtype \(subtype)")
        }
    }

    @Test func ignoresBitsAboveTheKeyCodeAndFlags() {
        #expect(MediaKeyDecoder.decode(subtype: 8, data1: (0x1234 << 32) | data1(16))?.key == .playPause)
    }

    @Test func onlyTheKeyCodeAndFlagsMatter() {
        // The low byte of the flags carries the repeat bit; the other seven bits are not ours.
        #expect(MediaKeyDecoder.decode(subtype: 8, data1: data1(16) | 0x0E)?.isRepeat == false)
        #expect(MediaKeyDecoder.decode(subtype: 8, data1: data1(16) | 0x0F)?.isRepeat == true)
    }
}

/// Feeds events to a `MediaKeyGate` with a scripted handler and records when the handler was asked.
/// A class, because `#expect` can't call a mutating method on a struct.
private final class GateHarness {
    var gate = MediaKeyGate()
    var asked: [MediaKey] = []
    let answer: (MediaKey) -> Bool

    init(answer: @escaping (MediaKey) -> Bool) {
        self.answer = answer
    }

    func send(_ event: MediaKeyEvent) -> Bool {
        gate.shouldSwallow(event) { key in
            asked.append(key)
            return answer(key)
        }
    }

    func press(_ key: MediaKey) -> Bool { send(MediaKeyEvent(key: key, isDown: true, isRepeat: false)) }
    func autoRepeat(_ key: MediaKey) -> Bool { send(MediaKeyEvent(key: key, isDown: true, isRepeat: true)) }
    func release(_ key: MediaKey) -> Bool { send(MediaKeyEvent(key: key, isDown: false, isRepeat: false)) }
}

@Suite struct MediaKeyGateTests {
    @Test func consumedPressSwallowsItsRepeatsAndRelease() {
        let harness = GateHarness { _ in true }
        #expect(harness.press(.playPause))
        #expect(harness.autoRepeat(.playPause))
        #expect(harness.autoRepeat(.playPause))
        #expect(harness.release(.playPause))
        #expect(harness.asked == [.playPause])
    }

    @Test func declinedPressPassesEverythingThrough() {
        let harness = GateHarness { _ in false }
        #expect(!harness.press(.next))
        #expect(!harness.autoRepeat(.next))
        #expect(!harness.release(.next))
        #expect(harness.asked == [.next])
    }

    @Test func handlerIsAskedOncePerPressNotPerRepeat() {
        let harness = GateHarness { _ in true }
        _ = harness.press(.volumeUp)
        for _ in 0..<5 { _ = harness.autoRepeat(.volumeUp) }
        _ = harness.release(.volumeUp)
        _ = harness.press(.volumeUp)
        #expect(harness.asked == [.volumeUp, .volumeUp])
    }

    @Test func eventsOfAPressWeNeverSawPassThrough() {
        // The tap may be installed while a key is already held.
        let harness = GateHarness { _ in true }
        #expect(!harness.autoRepeat(.mute))
        #expect(!harness.release(.mute))
        #expect(harness.asked.isEmpty)
    }

    @Test func keysAreIndependent() {
        let harness = GateHarness { $0 == .next }
        #expect(harness.press(.next))
        #expect(!harness.press(.previous))
        #expect(harness.autoRepeat(.next))
        #expect(!harness.autoRepeat(.previous))
        #expect(!harness.release(.previous))
        #expect(harness.release(.next))
    }

    @Test func eachPressIsDecidedAfresh() {
        var answers = [true, false, true]
        let harness = GateHarness { _ in answers.removeFirst() }
        #expect(harness.press(.playPause))
        #expect(harness.release(.playPause))
        // The second press is declined: its release must pass through even though the first press was consumed.
        #expect(!harness.press(.playPause))
        #expect(!harness.release(.playPause))
        #expect(harness.press(.playPause))
    }

    @Test func aNewPressReplacesAnUnfinishedOne() {
        // A key-up got lost: the next press is decided on its own, and a declined one is not treated as consumed.
        var answers = [true, false]
        let harness = GateHarness { _ in answers.removeFirst() }
        #expect(harness.press(.mute))
        #expect(!harness.press(.mute))
        #expect(!harness.autoRepeat(.mute))
        #expect(!harness.release(.mute))
    }

    @Test func aReleaseIsSwallowedOnlyOnce() {
        let harness = GateHarness { _ in true }
        _ = harness.press(.mute)
        #expect(harness.release(.mute))
        #expect(!harness.release(.mute))
    }

    @Test func resetForgetsConsumedPresses() {
        let harness = GateHarness { _ in true }
        _ = harness.press(.playPause)
        harness.gate.reset()
        #expect(!harness.autoRepeat(.playPause))
        #expect(!harness.release(.playPause))
    }
}
