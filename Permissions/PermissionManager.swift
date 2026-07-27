import AppKit
import AVFoundation
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

enum PermissionState: String {
    case granted = "Allowed"
    case denied = "Denied"
    case restricted = "Restricted by macOS"
    case notDetermined = "Not requested"
    case unavailable = "Unavailable"
}

enum PermissionResetError: LocalizedError {
    case missingBundleIdentifier
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            "WhisperKeys could not identify its bundle ID for the permission reset."
        case .commandFailed(let message):
            "macOS could not reset WhisperKeys’ permissions. \(message)"
        }
    }
}

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var microphone: PermissionState = .notDetermined
    @Published private(set) var accessibility: PermissionState = .notDetermined
    @Published private(set) var inputMonitoring: PermissionState = .notDetermined

    init() { refresh() }

    func refresh() {
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .denied
    }

    func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refresh()
            return true
        case .notDetermined:
            // WhisperKeys is an LSUIElement menu-bar app. Bringing it forward first makes
            // the system consent alert reliably visible rather than appearing behind another app.
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
                refresh()
                return false
            }
            openMicrophonePrivacySettings()
        @unknown default:
            break
        }
        refresh()
        return microphone == .granted
    }

    func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refresh()
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
    }

    /// Removes only this app's saved Accessibility and Input Monitoring decisions.
    /// macOS intentionally requires the user to grant the fresh requests themselves.
    func resetAccessibilityAndInputMonitoring() throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw PermissionResetError.missingBundleIdentifier
        }

        try resetTCC(service: "Accessibility", bundleIdentifier: bundleIdentifier)
        try resetTCC(service: "ListenEvent", bundleIdentifier: bundleIdentifier)
        refresh()
    }

    func openAccessibilityPrivacySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    func openInputMonitoringPrivacySettings() {
        openPrivacySettings(anchor: "Privacy_ListenEvent")
    }

    func openMicrophonePrivacySettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    /// Opens the corresponding Privacy & Security pane. `Privacy_ListenEvent` is the system
    /// anchor for Input Monitoring; requesting listen-event access alone cannot reopen the
    /// pane after the user has previously denied it.
    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"), configuration: .init())
        }
    }

    private func resetTCC(service: String, bundleIdentifier: String) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleIdentifier]
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PermissionResetError.commandFailed(output ?? "")
        }
    }
}

@MainActor
enum AppRestarter {
    /// Launches a new app instance before terminating this one, so a permissions reset never
    /// leaves the user without the setup window they need to continue.
    static func restart(completion: @escaping (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                completion(error)
                if error == nil {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}
