import AudioToolbox
import CoreAudio
import Foundation
import NowBarCore

/// The Mac's output volume, through CoreAudio on the default output device: the same volume and mute the
/// keyboard keys and Control Center change.
///
/// - Level: the device's virtual main volume (output scope, main element). `isAdjustable` means that
///   property exists and can be set.
/// - Mute: the device's mute property. Devices without one get an emulated mute: the level is remembered and
///   set to 0, then restored on unmute.
/// - Listeners on the volume, the mute and the default output device call `onChange` on the main actor, and
///   follow the default device when it changes.
@MainActor
public final class SystemVolumeController: SystemVolumeControlling {
    public var onChange: ((SystemVolume) -> Void)?

    public init() {}

    // MARK: Private state

    private struct Listener {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }

    private var isStarted = false
    private var boundDevice = HAL.unknownDevice
    private var deviceListeners: [Listener] = []
    private var defaultDeviceListener: Listener?
    private var lastPushed: SystemVolume?
    /// Set while mute is emulated (the device has no mute property): the level to restore.
    private var emulatedMute: (device: AudioObjectID, restoreLevel: Float)?

    // MARK: SystemVolumeControlling

    /// Read from CoreAudio each time, so it is right even between change notifications.
    public var current: SystemVolume {
        volume(of: HAL.defaultOutputDevice())
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        defaultDeviceListener = addListener(on: HAL.systemObject, HAL.defaultOutputAddress)
        bind(to: HAL.defaultOutputDevice())
        lastPushed = nil
        pushIfChanged()
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        if let defaultDeviceListener { remove(defaultDeviceListener) }
        defaultDeviceListener = nil
        removeDeviceListeners()
        boundDevice = HAL.unknownDevice
    }

    public func setLevel(_ level: Float) {
        guard level.isFinite else { return }
        let device = HAL.defaultOutputDevice()
        guard device != HAL.unknownDevice, HAL.isSettable(device, HAL.volumeAddress) else { return }
        let clamped = min(max(level, 0), 1)
        if clamped > 0 { unmute(device) }
        _ = HAL.write(device, HAL.volumeAddress, Float32(clamped))
        pushIfChanged()
    }

    public func setMuted(_ muted: Bool) {
        let device = HAL.defaultOutputDevice()
        guard device != HAL.unknownDevice else { return }
        if HAL.isSettable(device, HAL.muteAddress) {
            _ = HAL.write(device, HAL.muteAddress, UInt32(muted ? 1 : 0))
        } else if HAL.isSettable(device, HAL.volumeAddress) {
            // No mute switch on this device: fake it with the level.
            let level = HAL.read(device, HAL.volumeAddress, as: Float32.self) ?? 0
            if muted {
                if level > 0 {
                    emulatedMute = (device, level)
                    _ = HAL.write(device, HAL.volumeAddress, Float32(0))
                }
            } else if let emulated = emulatedMute, emulated.device == device {
                emulatedMute = nil
                if level <= HAL.silence { _ = HAL.write(device, HAL.volumeAddress, Float32(emulated.restoreLevel)) }
            }
        }
        pushIfChanged()
    }

    // MARK: Reading

    private func volume(of device: AudioObjectID) -> SystemVolume {
        guard device != HAL.unknownDevice else { return .unavailable }
        let level = min(max(HAL.read(device, HAL.volumeAddress, as: Float32.self) ?? 0, 0), 1)
        let isMuted: Bool
        if HAL.has(device, HAL.muteAddress) {
            isMuted = (HAL.read(device, HAL.muteAddress, as: UInt32.self) ?? 0) != 0
        } else {
            isMuted = emulatedMute?.device == device && level <= HAL.silence
        }
        return SystemVolume(level: level, isMuted: isMuted, isAdjustable: HAL.isSettable(device, HAL.volumeAddress))
    }

    private func unmute(_ device: AudioObjectID) {
        if emulatedMute?.device == device { emulatedMute = nil }
        if HAL.isSettable(device, HAL.muteAddress), (HAL.read(device, HAL.muteAddress, as: UInt32.self) ?? 0) != 0 {
            _ = HAL.write(device, HAL.muteAddress, UInt32(0))
        }
    }

    private func pushIfChanged() {
        let now = current
        guard now != lastPushed else { return }
        lastPushed = now
        onChange?(now)
    }

    // MARK: Listeners

    /// Moves the volume and mute listeners to `device`, the current default output.
    private func bind(to device: AudioObjectID) {
        removeDeviceListeners()
        // A mute we faked belongs to the old device; give it its volume back so it isn't stuck at 0. But only
        // while it is still silent: if its volume was changed since (with its own controls, say), that level is
        // the user's choice now, and the remembered one is just forgotten.
        if let emulated = emulatedMute, emulated.device != device {
            emulatedMute = nil
            if let level = HAL.read(emulated.device, HAL.volumeAddress, as: Float32.self), level <= HAL.silence {
                _ = HAL.write(emulated.device, HAL.volumeAddress, Float32(emulated.restoreLevel))
            }
        }
        boundDevice = device
        guard device != HAL.unknownDevice else { return }
        // Not every device has every property; the ones that fail to register are simply skipped.
        let addresses = [HAL.volumeAddress, HAL.muteAddress] + HAL.channelVolumeAddresses
        deviceListeners = addresses.compactMap { addListener(on: device, $0) }
    }

    private func removeDeviceListeners() {
        for listener in deviceListeners { remove(listener) }
        deviceListeners = []
    }

    private func addListener(on object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Listener? {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Delivered on the main queue (below).
            MainActor.assumeIsolated { self?.audioStateChanged() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return nil }
        return Listener(object: object, address: address, block: block)
    }

    private func remove(_ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
    }

    private func audioStateChanged() {
        guard isStarted else { return }
        let device = HAL.defaultOutputDevice()
        if device != boundDevice { bind(to: device) }
        pushIfChanged()
    }
}

/// Thin CoreAudio property helpers.
private enum HAL {
    /// Below this a level counts as silent.
    static let silence: Float = 0.0001

    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknownDevice = AudioObjectID(kAudioObjectUnknown)

    static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    /// The device's virtual main volume, 0...1.
    static let volumeAddress = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    static let muteAddress = outputAddress(kAudioDevicePropertyMute)
    /// Some devices only have per-channel volumes, with no main element. Listening to the main element and to
    /// the two stereo channels catches a change made either way.
    static let channelVolumeAddresses = [kAudioObjectPropertyElementMain, 1, 2].map {
        outputAddress(kAudioDevicePropertyVolumeScalar, element: $0)
    }

    private static func outputAddress(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    static func defaultOutputDevice() -> AudioObjectID {
        read(systemObject, defaultOutputAddress, as: AudioObjectID.self) ?? unknownDevice
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func read<Value: FixedWidthInteger & BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as: Value.Type) -> Value? {
        var value: Value = 0
        return read(object, address, into: &value) ? value : nil
    }

    static func read(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as: Float32.Type) -> Float32? {
        var value: Float32 = 0
        return read(object, address, into: &value) ? value : nil
    }

    private static func read<Value: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, into value: inout Value) -> Bool {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return false }
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    /// Writes only when the property exists and can be set.
    static func write<Value: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: Value) -> Bool {
        guard isSettable(object, address) else { return false }
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Value>.size), &value) == noErr
    }
}
