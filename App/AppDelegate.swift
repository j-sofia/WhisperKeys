import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) var shared: AppDelegate?

    private var dockVisibilityObservation: AnyCancellable?
    private weak var viewModel: AppViewModel?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?

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
    }

    func configure(viewModel: AppViewModel) {
        self.viewModel = viewModel
        configure(settings: viewModel.settings)
        presentOnboardingIfNeeded()
    }

    func configure(settings: AppSettings) {
        dockVisibilityObservation = settings.$showInDock
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.setDockVisibility(isVisible)
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
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 650),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to WhisperKeys"
        window.titlebarAppearsTransparent = true
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
    }

    private func closeSettingsWindow() {
        settingsWindow?.close()
        settingsWindow = nil
    }

    private func setDockVisibility(_ isVisible: Bool) {
        NSApplication.shared.setActivationPolicy(isVisible ? .regular : .accessory)
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
