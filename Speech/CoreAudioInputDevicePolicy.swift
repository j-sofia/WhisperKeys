import CoreAudio
import Foundation

/// Chooses the microphone WhisperKeys should use for a new dictation.
///
/// The policy is intentionally split into a pure `selectInputDeviceID` function and a CoreAudio
/// snapshot provider so unit tests can cover the AirPods/Bluetooth behavior without requiring
/// particular hardware on the test Mac.
struct CoreAudioInputDevicePolicy {
    struct Device: Equatable {
        let id: AudioDeviceID
        let name: String
        let transportType: UInt32
        let isInput: Bool

        var isBluetooth: Bool {
            transportType == kAudioDeviceTransportTypeBluetooth ||
            transportType == kAudioDeviceTransportTypeBluetoothLE
        }

        var isBuiltIn: Bool {
            transportType == kAudioDeviceTransportTypeBuiltIn
        }
    }

    struct Snapshot: Equatable {
        let defaultInputDeviceID: AudioDeviceID?
        let inputDevices: [Device]
    }

    var snapshot: () -> Snapshot

    init(snapshot: @escaping () -> Snapshot = CoreAudioInputDevicePolicy.currentSnapshot) {
        self.snapshot = snapshot
    }

    /// Returns the effective input device for the next capture.
    ///
    /// Explicit settings are preserved. Only System Default (`nil`) is adjusted, and only when the
    /// current default input is Bluetooth. In that case using the Bluetooth microphone would switch
    /// AirPods playback from A2DP to headset/HFP, so prefer the built-in Mac microphone, then any
    /// non-Bluetooth input. If no safer input exists, fall back to System Default.
    func effectiveInputDeviceID(for configuredInputDeviceID: AudioDeviceID?) -> AudioDeviceID? {
        Self.selectInputDeviceID(configuredInputDeviceID: configuredInputDeviceID, snapshot: snapshot())
    }

    static func selectInputDeviceID(
        configuredInputDeviceID: AudioDeviceID?,
        snapshot: Snapshot
    ) -> AudioDeviceID? {
        if let configuredInputDeviceID { return configuredInputDeviceID }

        guard let defaultInputDeviceID = snapshot.defaultInputDeviceID,
              let defaultDevice = snapshot.inputDevices.first(where: { $0.id == defaultInputDeviceID }),
              defaultDevice.isBluetooth else {
            return nil
        }

        if let builtInInput = snapshot.inputDevices.first(where: { $0.isInput && $0.isBuiltIn }) {
            return builtInInput.id
        }

        return snapshot.inputDevices.first(where: { $0.isInput && !$0.isBluetooth })?.id
    }

    static func currentSnapshot() -> Snapshot {
        Snapshot(
            defaultInputDeviceID: defaultInputDeviceID(),
            inputDevices: allAudioDevices().filter(\.isInput)
        )
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func allAudioDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.map { deviceID in
            Device(
                id: deviceID,
                name: deviceName(for: deviceID) ?? "Audio Device \(deviceID)",
                transportType: transportType(for: deviceID) ?? 0,
                isInput: hasInputStreams(deviceID)
            )
        }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr && dataSize > 0
    }

    private static func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        var transportType = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        return status == noErr ? transportType : nil
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? name as String : nil
    }
}
