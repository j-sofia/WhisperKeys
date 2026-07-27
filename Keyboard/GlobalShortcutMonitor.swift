import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Observes a recorded global shortcut without modifying or suppressing the original event.
/// Listening requires Input Monitoring permission, while emitted key events require Accessibility.
final class GlobalShortcutMonitor {
    var onAction: (() -> Void)?
    var onHoldStarted: (() -> Void)?
    var onHoldEnded: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcutConfiguration: ShortcutConfiguration?
    private var activationMode: ShortcutActivationMode = .doublePress
    private var doublePressInterval: TimeInterval = 0.35
    private var shortcutIsDown = false
    private var lastShortcutKeyDown: TimeInterval = 0

    func start(
        shortcut: ShortcutConfiguration,
        activationMode: ShortcutActivationMode,
        doublePressIntervalMilliseconds: Int
    ) throws {
        stop()
        guard shortcut.isEnabled else { return }
        guard CGPreflightListenEventAccess() else {
            throw PermissionError.inputMonitoringRequired
        }

        shortcutConfiguration = shortcut
        self.activationMode = activationMode
        doublePressInterval = Double(min(max(doublePressIntervalMilliseconds, 200), 800)) / 1_000

        let eventTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = eventTypes.reduce(CGEventMask()) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            shortcutConfiguration = nil
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
        shortcutConfiguration = nil
        shortcutIsDown = false
        lastShortcutKeyDown = 0
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard let shortcutConfiguration,
              let shortcutKeyCode = shortcutConfiguration.keyCode,
              event.getIntegerValueField(.keyboardEventKeycode) == shortcutKeyCode
        else { return }

        switch type {
        case .keyDown:
            guard !shortcutConfiguration.isModifierKey,
                  matchesModifiers(for: event, shortcut: shortcutConfiguration),
                  event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            else { return }
            shortcutIsDown = true
            shortcutPressed()

        case .keyUp:
            guard !shortcutConfiguration.isModifierKey else { return }
            shortcutIsDown = false
            shortcutReleased()

        case .flagsChanged:
            guard shortcutConfiguration.isModifierKey else { return }
            // `flagsChanged` has no dedicated down/up value. A matching modifier emits one
            // event for each transition, so keeping the local state preserves left/right keys.
            shortcutIsDown.toggle()
            if shortcutIsDown {
                guard matchesModifiers(for: event, shortcut: shortcutConfiguration) else { return }
                shortcutPressed()
            } else {
                shortcutReleased()
            }

        default:
            break
        }
    }

    private func matchesModifiers(for event: CGEvent, shortcut: ShortcutConfiguration) -> Bool {
        let required = CGEventFlags(rawValue: shortcut.modifierFlagsRawValue)
            .intersection(Self.shortcutModifierFlags)
        var active = event.flags.intersection(Self.shortcutModifierFlags)
        if let keyCode = shortcut.keyCode,
           let shortcutModifierFlag = Self.modifierFlag(for: keyCode) {
            active.subtract(shortcutModifierFlag)
        }
        return active == required
    }

    private func shortcutPressed() {
        switch activationMode {
        case .singlePress:
            deliverAction()
        case .doublePress:
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShortcutKeyDown <= doublePressInterval {
                lastShortcutKeyDown = 0
                deliverAction()
            } else {
                lastShortcutKeyDown = now
            }
        case .hold:
            deliverHoldStarted()
        }
    }

    private func shortcutReleased() {
        guard activationMode == .hold else { return }
        deliverHoldEnded()
    }

    private func deliverAction() {
        DispatchQueue.main.async { [weak self] in self?.onAction?() }
    }

    private func deliverHoldStarted() {
        DispatchQueue.main.async { [weak self] in self?.onHoldStarted?() }
    }

    private func deliverHoldEnded() {
        DispatchQueue.main.async { [weak self] in self?.onHoldEnded?() }
    }

    private static let shortcutModifierFlags: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand
    ]

    private static func modifierFlag(for keyCode: Int64) -> CGEventFlags? {
        switch Int(keyCode) {
        case kVK_RightOption, kVK_Option: .maskAlternate
        case kVK_RightCommand, kVK_Command: .maskCommand
        case kVK_RightControl, kVK_Control: .maskControl
        case kVK_RightShift, kVK_Shift: .maskShift
        default: nil
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }
}

enum PermissionError: LocalizedError {
    case inputMonitoringRequired

    var errorDescription: String? {
        "Input Monitoring permission is required for the global shortcut."
    }
}
