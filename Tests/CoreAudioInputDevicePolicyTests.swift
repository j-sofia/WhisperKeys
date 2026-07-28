import CoreAudio
import XCTest

@testable import WhisperKeys

final class CoreAudioInputDevicePolicyTests: XCTestCase {
    func testExplicitlySelectedInputDeviceIsPreservedEvenWhenDefaultIsBluetooth() {
        let snapshot = makeSnapshot(
            defaultInputDeviceID: 1,
            devices: [
                device(id: 1, transportType: kAudioDeviceTransportTypeBluetooth),
                device(id: 2, transportType: kAudioDeviceTransportTypeBuiltIn),
                device(id: 3, transportType: kAudioDeviceTransportTypeUSB)
            ]
        )

        let selected = CoreAudioInputDevicePolicy.selectInputDeviceID(
            configuredInputDeviceID: 99,
            snapshot: snapshot
        )

        XCTAssertEqual(selected, 99)
    }

    func testSystemDefaultUsesNilWhenDefaultInputIsNotBluetooth() {
        let snapshot = makeSnapshot(
            defaultInputDeviceID: 2,
            devices: [
                device(id: 1, transportType: kAudioDeviceTransportTypeBluetooth),
                device(id: 2, transportType: kAudioDeviceTransportTypeBuiltIn)
            ]
        )

        let selected = CoreAudioInputDevicePolicy.selectInputDeviceID(
            configuredInputDeviceID: nil,
            snapshot: snapshot
        )

        XCTAssertNil(selected)
    }

    func testSystemDefaultBluetoothPrefersBuiltInInput() {
        let snapshot = makeSnapshot(
            defaultInputDeviceID: 1,
            devices: [
                device(id: 1, transportType: kAudioDeviceTransportTypeBluetooth),
                device(id: 3, transportType: kAudioDeviceTransportTypeUSB),
                device(id: 2, transportType: kAudioDeviceTransportTypeBuiltIn)
            ]
        )

        let selected = CoreAudioInputDevicePolicy.selectInputDeviceID(
            configuredInputDeviceID: nil,
            snapshot: snapshot
        )

        XCTAssertEqual(selected, 2)
    }

    func testSystemDefaultBluetoothLEPrefersBuiltInInput() {
        let snapshot = makeSnapshot(
            defaultInputDeviceID: 1,
            devices: [
                device(id: 1, transportType: kAudioDeviceTransportTypeBluetoothLE),
                device(id: 2, transportType: kAudioDeviceTransportTypeBuiltIn)
            ]
        )

        let selected = CoreAudioInputDevicePolicy.selectInputDeviceID(
            configuredInputDeviceID: nil,
            snapshot: snapshot
        )

        XCTAssertEqual(selected, 2)
    }

    func testSystemDefaultBluetoothFallsBackToNonBluetoothInputWhenBuiltInIsUnavailable() {
        let snapshot = makeSnapshot(
            defaultInputDeviceID: 1,
            devices: [
                device(id: 1, transportType: kAudioDeviceTransportTypeBluetooth),
                device(id: 3, transportType: kAudioDeviceTransportTypeUSB)
            ]
        )

        let selected = CoreAudioInputDevicePolicy.selectInputDeviceID(
            configuredInputDeviceID: nil,
            snapshot: snapshot
        )

        XCTAssertEqual(selected, 3)
    }

    func testSystemDefaultBluetoothStaysNilWhenNoSaferInputExists() {
        let snapshot = makeSnapshot(
            defaultInputDeviceID: 1,
            devices: [
                device(id: 1, transportType: kAudioDeviceTransportTypeBluetooth)
            ]
        )

        let selected = CoreAudioInputDevicePolicy.selectInputDeviceID(
            configuredInputDeviceID: nil,
            snapshot: snapshot
        )

        XCTAssertNil(selected)
    }

    private func makeSnapshot(
        defaultInputDeviceID: AudioDeviceID?,
        devices: [CoreAudioInputDevicePolicy.Device]
    ) -> CoreAudioInputDevicePolicy.Snapshot {
        CoreAudioInputDevicePolicy.Snapshot(
            defaultInputDeviceID: defaultInputDeviceID,
            inputDevices: devices
        )
    }

    private func device(
        id: AudioDeviceID,
        transportType: UInt32,
        isInput: Bool = true
    ) -> CoreAudioInputDevicePolicy.Device {
        CoreAudioInputDevicePolicy.Device(
            id: id,
            name: "Device \(id)",
            transportType: transportType,
            isInput: isInput
        )
    }
}
