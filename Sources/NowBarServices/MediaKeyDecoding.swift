import Foundation
import NowBarCore

/// One media key event, decoded from an NX_SYSDEFINED event.
struct MediaKeyEvent: Equatable {
    var key: MediaKey
    /// True for key-down (including auto-repeat), false for key-up.
    var isDown: Bool
    /// True for the auto-repeat events that follow the first key-down while a key is held.
    var isRepeat: Bool
}

/// Decodes the `data1` field of aux-control-button events (NX_SYSDEFINED, subtype 8). Pure, so it is unit tested.
enum MediaKeyDecoder {
    /// CGEventType raw value of NX_SYSDEFINED.
    static let systemDefinedEventType: UInt32 = 14
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS: the media, volume and brightness keys.
    static let auxControlButtonsSubtype: Int16 = 8

    /// key code in the top 16 bits, flags in the bottom 16: the key state in the high byte of the flags
    /// (0xA down, 0xB up) and the repeat bit in bit 0.
    static func decode(subtype: Int16, data1: Int) -> MediaKeyEvent? {
        guard subtype == auxControlButtonsSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        guard let key = key(forKeyCode: keyCode) else { return nil }
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        let isRepeat = (flags & 0x1) != 0
        return MediaKeyEvent(key: key, isDown: isDown, isRepeat: isRepeat)
    }

    /// NX_KEYTYPE_* values. Anything else (brightness, eject, keyboard backlight) is not ours.
    static func key(forKeyCode keyCode: Int) -> MediaKey? {
        switch keyCode {
        case 16: return .playPause      // NX_KEYTYPE_PLAY
        case 17, 19: return .next       // NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST
        case 18, 20: return .previous   // NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND
        case 7: return .mute            // NX_KEYTYPE_MUTE
        case 0: return .volumeUp        // NX_KEYTYPE_SOUND_UP
        case 1: return .volumeDown      // NX_KEYTYPE_SOUND_DOWN
        default: return nil
        }
    }
}

/// Decides which events of a key press macOS gets to see.
///
/// The handler is asked once per press, on the first key-down that isn't an auto-repeat. If it consumes the
/// press, that press's auto-repeats and its key-up are consumed as well, so macOS never sees half a press.
/// If it doesn't, all of them pass through.
struct MediaKeyGate {
    private var consumed: Set<MediaKey> = []

    /// Returns true when the event must be swallowed.
    mutating func shouldSwallow(_ event: MediaKeyEvent, handler: (MediaKey) -> Bool) -> Bool {
        guard event.isDown else {
            // Key-up: swallowed only if its press was.
            return consumed.remove(event.key) != nil
        }
        if event.isRepeat { return consumed.contains(event.key) }
        if handler(event.key) {
            consumed.insert(event.key)
            return true
        }
        consumed.remove(event.key)
        return false
    }

    mutating func reset() {
        consumed.removeAll()
    }
}
