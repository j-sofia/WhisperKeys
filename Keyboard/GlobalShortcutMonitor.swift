import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Observes a user-selected modifier key; it never modifies or suppresses the user's original event.
/// Listening requires Input Monitoring permission, while emitted key events require Accessibility.
final class GlobalShortcutMonitor {
    var onAction: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcutKeyCode: Int64?
    private var rightOptionIsDown = false
    private var lastShortcutKeyDown: TimeInterval = 0

    func start(shortcutKey: ShortcutKey) throws {
        stop()
        guard let keyCode = shortcutKey.keyCode else { return }
        guard CGPreflightListenEventAccess() else {
            throw PermissionError.inputMonitoringRequired
        }

        rightOptionIsDown = false
        lastShortcutKeyDown = 0
        shortcutKeyCode = keyCode
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw PermissionError.inputMonitoringRequired
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        shortcutKeyCode = nil
        rightOptionIsDown = false
        lastShortcutKeyDown = 0
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == shortcutKeyCode
        else { return }

        rightOptionIsDown.toggle()
        if rightOptionIsDown {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShortcutKeyDown < 0.35 {
                lastShortcutKeyDown = 0
                deliver()
            } else {
                lastShortcutKeyDown = now
            }
        }
    }

    private func deliver() {
        DispatchQueue.main.async { [weak self] in self?.onAction?() }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }
}

private extension ShortcutKey {
    var keyCode: Int64? {
        switch self {
        case .rightOption: Int64(kVK_RightOption)
        case .leftOption: Int64(kVK_Option)
        case .rightCommand: Int64(kVK_RightCommand)
        case .leftCommand: Int64(kVK_Command)
        case .rightControl: Int64(kVK_RightControl)
        case .leftControl: Int64(kVK_Control)
        case .disabled: nil
        }
    }
}

enum PermissionError: LocalizedError {
    case inputMonitoringRequired

    var errorDescription: String? {
        "Input Monitoring permission is required for the global shortcut."
    }
}
