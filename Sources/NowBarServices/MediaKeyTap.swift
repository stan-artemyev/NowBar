import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import NowBarCore

/// Intercepts the keyboard media keys system-wide with an active event tap, which needs Accessibility permission.
///
/// - While `isEnabled`, trust is polled every 2 seconds; the tap is installed once NowBar is trusted and removed
///   if trust is revoked or `isEnabled` becomes false. `onTrustChange` reports changes seen by that poll.
/// - The tap runs on the main run loop. `handler` is called once per key press; if it returns true the press
///   (with its repeats and key-up) never reaches macOS.
@MainActor
public final class MediaKeyTap: MediaKeyIntercepting {
    public var handler: ((MediaKey) -> Bool)?
    public var onTrustChange: ((Bool) -> Void)?

    public var isEnabled = false {
        didSet {
            if isEnabled != oldValue { enabledDidChange() }
        }
    }

    public var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    public init() {
        lastKnownTrust = AXIsProcessTrusted()
    }

    deinit {
        // Only touches the thread-safe tap object, so it is fine off the main actor.
        tap.remove()
    }

    // MARK: Private state

    private let tap = EventTap()
    private var gate = MediaKeyGate()
    private var lastKnownTrust: Bool
    private var pollTask: Task<Void, Never>?
    private var hasShownPrompt = false

    private static let trustPollInterval = Duration.seconds(2)
    private static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    // MARK: MediaKeyIntercepting

    /// Shows the system Accessibility prompt. macOS may not show it again after it has been dismissed, so any
    /// later request while still untrusted opens the Accessibility pane of System Settings instead.
    public func requestTrust() {
        guard !AXIsProcessTrusted() else { return }
        if !hasShownPrompt {
            hasShownPrompt = true
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        } else if let url = Self.accessibilitySettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Trust and tap lifecycle

    private func enabledDidChange() {
        pollTask?.cancel()
        pollTask = nil
        guard isEnabled else {
            tap.remove()
            gate.reset()
            return
        }
        evaluateTrust()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.trustPollInterval)
                guard !Task.isCancelled, let self, self.isEnabled else { return }
                self.evaluateTrust()
            }
        }
    }

    /// Installs or removes the tap to match the current trust, then reports a change of trust.
    private func evaluateTrust() {
        let trusted = AXIsProcessTrusted()
        if isEnabled && trusted {
            // Creating the tap can still fail; the next poll tries again.
            if tap.install(owner: self) { tap.reenableIfDisabled() }
        } else {
            tap.remove()
            gate.reset()
        }
        if trusted != lastKnownTrust {
            lastKnownTrust = trusted
            onTrustChange?(trusted)
        }
    }

    // MARK: Events

    /// Called from the tap callback on the main thread. Returns true to swallow the event. Internal so tests can
    /// feed it synthetic events without installing a tap.
    func shouldSwallow(_ cgEvent: CGEvent) -> Bool {
        guard let event = NSEvent(cgEvent: cgEvent), event.type == .systemDefined,
              let decoded = MediaKeyDecoder.decode(subtype: event.subtype.rawValue, data1: event.data1) else {
            return false
        }
        return gate.shouldSwallow(decoded) { key in handler?(key) ?? false }
    }
}

/// Owns the event tap and its run loop source. Kept apart from the (main actor) `MediaKeyTap` so the C callback
/// and `deinit` can reach it. Everything runs on the main thread.
private final class EventTap: @unchecked Sendable {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    weak var owner: MediaKeyTap?

    /// Installs the tap if it isn't already. Returns whether it is installed afterwards.
    @MainActor
    func install(owner: MediaKeyTap) -> Bool {
        if port != nil { return true }
        let mask = CGEventMask(1) << CGEventMask(MediaKeyDecoder.systemDefinedEventType)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.owner = owner
        self.port = port
        self.source = source
        return true
    }

    /// Turns the tap back on if macOS switched it off without a disabled event reaching the callback.
    func reenableIfDisabled() {
        if let port, !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    func remove() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        port = nil
        source = nil
    }

    /// The tap callback body. Must return quickly and never block.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a tap off when it is too slow or after a secure-input moment: turn it back on.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return passThrough
        default:
            break
        }
        guard type.rawValue == MediaKeyDecoder.systemDefinedEventType, let owner else { return passThrough }
        // The source is on the main run loop, so this always runs on the main thread.
        let swallow = MainActor.assumeIsolated { owner.shouldSwallow(event) }
        return swallow ? nil : passThrough
    }
}

private func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
