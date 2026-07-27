import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) var shared: AppDelegate?

    private var dockVisibilityObservation: AnyCancellable?
    private var appearanceObservation: AnyCancellable?
    private var activityObservation: AnyCancellable?
    private weak var viewModel: AppViewModel?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let menuPopover = NSPopover()
    private let onboardingTipPopover = NSPopover()
    private var onboardingTipDismissWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setDockVisibility(UserDefaults.standard.bool(forKey: "showInDock"))
        if let viewModel = AppRuntime.viewModel {
            configure(viewModel: viewModel)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.shutdown()
        dockVisibilityObservation?.cancel()
        dockVisibilityObservation = nil
        appearanceObservation?.cancel()
        appearanceObservation = nil
        activityObservation?.cancel()
        activityObservation = nil
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
            }
        updateMenuBarIcon(for: viewModel.activity)
    }

    private func updateMenuBarIcon(for activity: AppActivity) {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        switch activity {
        case .recording: symbolName = "mic.fill"
        case .transcribing, .typing, .installingModel: symbolName = "waveform.circle.fill"
        case .error: symbolName = "exclamationmark.triangle.fill"
        case .idle: symbolName = "waveform"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "WhisperKeys")
        image?.isTemplate = true
        button.image = image
    }

    @objc private func toggleMenuPopover() {
        guard let button = statusItem?.button else { return }
        dismissOnboardingTip()
        if menuPopover.isShown {
            menuPopover.performClose(nil)
        } else {
            menuPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            menuPopover.contentViewController?.view.window?.makeKey()
        }
    }

    static func presentOnboarding() {
        shared?.presentOnboardingIfNeeded()
    }

    static func presentSettings() {
        shared?.presentSettingsWindow()
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
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        guard let viewModel else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperKeys Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: SettingsView(viewModel: viewModel) { [weak self] in
                self?.closeSettingsWindow()
            }
        )
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
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
        guard settings.shortcutKey != .disabled else {
            return "Use this menu bar icon to start and end transcription."
        }
        return "Double-press \(settings.shortcutKey.displayName) to start WhisperKeys. Double-press it again to end transcription."
    }
}

@MainActor
enum AppRuntime {
    static var viewModel: AppViewModel? {
        didSet {
            if let viewModel {
                AppDelegate.shared?.configure(viewModel: viewModel)
            }
        }
    }
}
