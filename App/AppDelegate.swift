import AppKit
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var dockVisibilityObservation: AnyCancellable?
    private var appearanceObservation: AnyCancellable?
    private var activityObservation: AnyCancellable?
    private var reviewTranscriptionObservation: AnyCancellable?
    private weak var viewModel: AppViewModel?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var waveformPanel: NSPanel?
    /// The normal review panel deliberately has no keyboard focus. Selecting Edit gives the
    /// non-activating panel key focus without activating WhisperKeys or changing Spaces.
    private var reviewPanelIsEditing = false
    private var statusItem: NSStatusItem?
    private let menuPopover = NSPopover()
    private let onboardingTipPopover = NSPopover()
    private var onboardingTipDismissWorkItem: DispatchWorkItem?

    override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setDockVisibility(UserDefaults.standard.bool(forKey: "showInDock"))
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.shutdown()
        dockVisibilityObservation?.cancel()
        dockVisibilityObservation = nil
        appearanceObservation?.cancel()
        appearanceObservation = nil
        activityObservation?.cancel()
        activityObservation = nil
        reviewTranscriptionObservation?.cancel()
        reviewTranscriptionObservation = nil
    }

    func configure(viewModel: AppViewModel) {
        self.viewModel = viewModel
        configure(settings: viewModel.settings)
        configureMenuBarItem(with: viewModel)
        presentOnboardingIfNeeded()
    }

    func configure(settings: AppSettings) {
        dockVisibilityObservation = settings.$showInDock
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.setDockVisibility(isVisible)
            }

        appearanceObservation = settings.$appearanceID
            .removeDuplicates()
            .sink { [weak self] appearanceID in
                let appearance = AppAppearance(rawValue: appearanceID) ?? .system
                self?.applyAppearance(appearance)
            }
    }

    private func configureMenuBarItem(with viewModel: AppViewModel) {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            guard let button = item.button else { return }

            button.target = self
            button.action = #selector(toggleMenuPopover)
            button.sendAction(on: [.leftMouseUp])
            button.toolTip = "WhisperKeys"
            statusItem = item

            menuPopover.behavior = .transient
            menuPopover.animates = true
            menuPopover.contentSize = NSSize(width: 294, height: 360)
            menuPopover.contentViewController = NSHostingController(
                rootView: MenuContentView(viewModel: viewModel) { [weak self, weak viewModel] in
                    self?.menuPopover.performClose(nil)
                    viewModel?.startDictation()
                }
            )

            onboardingTipPopover.behavior = .transient
            onboardingTipPopover.animates = true
            onboardingTipPopover.contentSize = NSSize(width: 326, height: 142)
        }

        activityObservation = viewModel.$activity
            .receive(on: RunLoop.main)
            .sink { [weak self] activity in
                self?.updateMenuBarIcon(for: activity)
                self?.updateWaveformPopup(for: activity)
            }
        reviewTranscriptionObservation = viewModel.$reviewTranscription
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] _ in
                guard let self, let viewModel, viewModel.isReviewBeforeTyping else { return }
                self.resizeWaveformPopup(for: viewModel.activity, viewModel: viewModel)
            }
        updateMenuBarIcon(for: viewModel.activity)
        updateWaveformPopup(for: viewModel.activity)
    }

    private func updateMenuBarIcon(for activity: AppActivity) {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        switch activity {
        case .recording: symbolName = "mic.fill"
        case .transcribing, .reviewing, .typing, .installingModel: symbolName = "waveform.circle.fill"
        case .error: symbolName = "exclamationmark.triangle.fill"
        case .idle: symbolName = "waveform"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "WhisperKeys")
        image?.isTemplate = true
        button.image = image
    }

    private func updateWaveformPopup(for activity: AppActivity) {
        guard let viewModel else { return }
        if activity != .reviewing {
            reviewPanelIsEditing = false
        }
        let shouldShow = activity == .recording
            || (viewModel.isReviewBeforeTyping && (activity == .transcribing || activity == .reviewing))
        guard shouldShow else {
            waveformPanel?.orderOut(nil)
            return
        }
        presentWaveformPopup(for: activity)
    }

    /// A non-activating floating panel keeps the microphone preview visible above the app the
    /// user is dictating into, including fullscreen apps, without taking keyboard focus away.
    private func presentWaveformPopup(for activity: AppActivity) {
        guard let viewModel else { return }
        let size = waveformPopupSize(for: activity, viewModel: viewModel)
        let needsKeyboardFocus = activity == .reviewing && reviewPanelIsEditing

        let panel: NSPanel
        if let waveformPanel {
            panel = waveformPanel
        } else {
            panel = WaveformPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .canJoinAllApplications,
                .fullScreenAuxiliary,
                .transient,
                .ignoresCycle
            ]
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentView = NSHostingView(
                rootView: LiveWaveformPopupView(viewModel: viewModel)
            )
            waveformPanel = panel
        }
        // A pop-up-menu level panel stays above a full-screen app. It remains non-activating in
        // every state, so even Edit does not pull the user out of the target app's Space.
        panel.level = activity == .reviewing ? .popUpMenu : .floating
        panel.setContentSize(size)
        positionWaveformPanel(panel, for: viewModel.dictationTarget)
        if needsKeyboardFocus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Gives the non-activating review panel text focus while retaining the target app's Space.
    static func editReviewTranscription() {
        (NSApp.delegate as? AppDelegate)?.focusReviewEditor()
    }

    private func focusReviewEditor() {
        guard let viewModel, viewModel.activity == .reviewing else { return }
        reviewPanelIsEditing = true
        presentWaveformPopup(for: .reviewing)
    }

    private func waveformPopupSize(for activity: AppActivity, viewModel: AppViewModel) -> NSSize {
        guard viewModel.isReviewBeforeTyping else { return NSSize(width: 294, height: 168) }
        return WaveformPopupLayout.panelSize(
            for: activity,
            transcript: viewModel.reviewTranscription
        )
    }

    private func resizeWaveformPopup(for activity: AppActivity, viewModel: AppViewModel) {
        guard let waveformPanel,
              activity == .recording || activity == .transcribing || activity == .reviewing
        else {
            return
        }
        waveformPanel.setContentSize(waveformPopupSize(for: activity, viewModel: viewModel))
        positionWaveformPanel(waveformPanel, for: viewModel.dictationTarget)
    }

    private func positionWaveformPanel(_ panel: NSPanel, for application: NSRunningApplication?) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = screen(for: application)
            ?? NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
        if let screen {
            let visibleFrame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(
                    x: visibleFrame.midX - panel.frame.width / 2,
                    y: visibleFrame.maxY - panel.frame.height - 48
                )
            )
        }
    }

    /// Full-screen apps can occupy another display or a different Space than the mouse's current
    /// location. Use the target process's largest visible window to select the correct display.
    private func screen(for application: NSRunningApplication?) -> NSScreen? {
        guard let application,
              let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]]
        else {
            return nil
        }

        let targetPID = application.processIdentifier
        let bounds = windowInfo.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == targetPID,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (dictionary["X"] as? NSNumber)?.doubleValue,
                  let y = (dictionary["Y"] as? NSNumber)?.doubleValue,
                  let width = (dictionary["Width"] as? NSNumber)?.doubleValue,
                  let height = (dictionary["Height"] as? NSNumber)?.doubleValue,
                  width > 0,
                  height > 0
            else {
                return nil
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        guard let largestWindow = bounds.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return nil
        }

        // Quartz window bounds use a top-left origin; AppKit screen frames use a bottom-left
        // origin. Convert before comparing the target window with the available displays.
        let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? largestWindow.maxY
        let appKitBounds = CGRect(
            x: largestWindow.minX,
            y: desktopTop - largestWindow.maxY,
            width: largestWindow.width,
            height: largestWindow.height
        )
        return NSScreen.screens.max { lhs, rhs in
            overlapArea(lhs.frame, with: appKitBounds) < overlapArea(rhs.frame, with: appKitBounds)
        }
    }

    private func overlapArea(_ lhs: CGRect, with rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        guard !overlap.isNull else { return 0 }
        return overlap.width * overlap.height
    }

    @objc private func toggleMenuPopover() {
        guard let button = statusItem?.button else { return }
        dismissOnboardingTip()
        if menuPopover.isShown {
            menuPopover.performClose(nil)
        } else {
            menuPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            configureMenuBarOverlay(menuPopover)
        }
    }

    /// Popovers created from a status item are initially regular app windows. Promote their
    /// backing window after presentation so a menu remains visible and interactive over a
    /// fullscreen window owned by another app.
    private func configureMenuBarOverlay(_ popover: NSPopover) {
        guard let window = popover.contentViewController?.view.window else { return }

        window.level = .popUpMenu
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        window.makeKeyAndOrderFront(nil)
    }

    static func presentOnboarding() {
        (NSApp.delegate as? AppDelegate)?.presentOnboardingIfNeeded()
    }

    static func presentSettings() {
        (NSApp.delegate as? AppDelegate)?.presentSettingsWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard viewModel?.settings.showInDock == true else { return false }

        // During setup, the Dock icon must return the user to the onboarding flow
        // rather than opening Settings, so they can continue where they left off.
        if viewModel?.settings.needsOnboarding == true {
            presentOnboardingIfNeeded()
            return true
        }

        presentSettingsWindow()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let quitItem = menu.addItem(
            withTitle: "Quit WhisperKeys",
            action: #selector(quitFromDock),
            keyEquivalent: ""
        )
        quitItem.target = self
        return menu
    }

    @objc private func quitFromDock() {
        NSApplication.shared.terminate(nil)
    }

    private func presentSettingsWindow() {
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            guard let viewModel else { return }
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 610, height: 620),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "WhisperKeys Settings"
            newWindow.titlebarAppearsTransparent = true
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.contentView = NSHostingView(
                rootView: SettingsView(viewModel: viewModel) { [weak self] in
                    self?.closeSettingsWindow()
                }
            )
            newWindow.center()
            settingsWindow = newWindow
            window = newWindow
        }

        // A status-item popover remains key until it is closed. Dismiss it before
        // bringing Settings forward so a previously opened Settings window regains
        // both window and application focus.
        menuPopover.performClose(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            onboardingWindow = nil
        } else if window === settingsWindow {
            settingsWindow = nil
        }
    }

    private func presentOnboardingIfNeeded() {
        guard let viewModel, viewModel.settings.needsOnboarding else { return }

        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to WhisperKeys"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: OnboardingView(viewModel: viewModel) { [weak self] in
                self?.closeOnboarding()
            }
        )
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        showOnboardingTip()
    }

    private func showOnboardingTip() {
        guard let button = statusItem?.button, let viewModel else { return }
        menuPopover.performClose(nil)
        dismissOnboardingTip()

        onboardingTipPopover.contentViewController = NSHostingController(
            rootView: OnboardingMenuBarTip(settings: viewModel.settings)
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak button] in
            guard let self, let button else { return }
            self.onboardingTipPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.configureMenuBarOverlay(self.onboardingTipPopover)
            let dismissWorkItem = DispatchWorkItem { [weak self] in
                self?.dismissOnboardingTip()
            }
            self.onboardingTipDismissWorkItem = dismissWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: dismissWorkItem)
        }
    }

    private func dismissOnboardingTip() {
        onboardingTipDismissWorkItem?.cancel()
        onboardingTipDismissWorkItem = nil
        onboardingTipPopover.performClose(nil)
    }

    private func closeSettingsWindow() {
        settingsWindow?.close()
        settingsWindow = nil
    }

    private func setDockVisibility(_ isVisible: Bool) {
        NSApplication.shared.setActivationPolicy(isVisible ? .regular : .accessory)
    }

    /// Applying System clears the override, so existing AppKit and SwiftUI windows
    /// immediately inherit the macOS appearance again.
    private func applyAppearance(_ appearance: AppAppearance) {
        switch appearance {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private final class WaveformPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct OnboardingMenuBarTip: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BrandAppIcon(size: 40, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text("You’re all set")
                    .font(.headline)
                Text(instructions)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 326, alignment: .leading)
    }

    private var instructions: String {
        guard settings.shortcutIsEnabled else {
            return "Use this menu bar icon to start and end transcription."
        }
        switch settings.shortcutActivationMode {
        case .singlePress:
            return "Press \(settings.shortcutConfiguration.displayName) to start WhisperKeys. Press it again to end transcription."
        case .doublePress:
            return "Double-press \(settings.shortcutConfiguration.displayName) to start WhisperKeys. Double-press it again to end transcription."
        case .hold:
            return "Hold \(settings.shortcutConfiguration.displayName) to dictate, then release it to end transcription."
        }
    }
}
