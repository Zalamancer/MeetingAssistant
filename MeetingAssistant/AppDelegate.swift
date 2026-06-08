import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    // Coordinator - main orchestrator
    private let coordinator = MeetingAssistantCoordinator.shared
    private let settings = SettingsManager.shared

    // Use SwiftUI view
    private var useSwiftUI = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - this is a menu bar only app
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupNotifications()
        setupCoordinator()

        // Request notification permission
        coordinator.requestNotificationPermission()

        // Show floating window on launch if configured
        if settings.showFloatingOnLaunch && settings.displayMode != .menuBar {
            FloatingWindowManager.shared.showFloatingWindow()
        }

        // Restore previous state if available
        Task {
            await coordinator.restoreState()
        }

        // Initialize debug window manager (sets up global shortcuts)
        _ = DebugWindowManager.shared

        Logger.log("MeetingAssistant started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save state before quitting
        coordinator.saveState()

        Task {
            await coordinator.cleanup()
        }
    }

    private func setupCoordinator() {
        // Setup coordinator callbacks
        coordinator.onMeetingStarted = { [weak self] meeting in
            self?.updateStatusIcon(capturing: true)
            self?.coordinator.sendNotification(
                title: "Meeting Started",
                body: meeting.title
            )
        }

        coordinator.onMeetingEnded = { [weak self] summary in
            self?.updateStatusIcon(capturing: false)
            self?.coordinator.sendNotification(
                title: "Meeting Ended",
                body: "\(summary.formattedDuration) - \(summary.transcriptWordCount) words captured"
            )
        }

        coordinator.onError = { error in
            Logger.log("Coordinator error: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Meeting Assistant")
            button.action = #selector(togglePopover)
            button.target = self

            // Right-click for menu
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        if useSwiftUI {
            // SwiftUI view
            let swiftUIView = MenuBarWidgetView()
            let hostingController = NSHostingController(rootView: swiftUIView)
            popover.contentViewController = hostingController
            popover.contentSize = NSSize(width: 320, height: 420)
        } else {
            // AppKit view
            popover.contentViewController = WidgetViewController()
            popover.contentSize = NSSize(width: 320, height: 220)
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings),
            name: .openSettings,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleCapture),
            name: .toggleCapture,
            object: nil
        )
    }

    // MARK: - Actions

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            showPopover(sender)
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                showPopover(sender)
            }
        }
    }

    private func showPopover(_ sender: NSStatusBarButton) {
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()

        let isActive = coordinator.state.isCapturing
        let captureItem = NSMenuItem(
            title: isActive ? "Stop Meeting" : "Start Meeting",
            action: #selector(toggleCapture),
            keyEquivalent: "c"
        )
        captureItem.target = self
        menu.addItem(captureItem)

        if isActive {
            let pauseItem = NSMenuItem(
                title: coordinator.state == .paused ? "Resume" : "Pause",
                action: #selector(togglePause),
                keyEquivalent: "p"
            )
            pauseItem.target = self
            menu.addItem(pauseItem)
        }

        menu.addItem(NSMenuItem.separator())

        let floatingItem = NSMenuItem(
            title: "Floating Window (⇧⌘M)",
            action: #selector(toggleFloatingWindow),
            keyEquivalent: "m"
        )
        floatingItem.keyEquivalentModifierMask = [.command, .shift]
        floatingItem.target = self
        menu.addItem(floatingItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(handleOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Debug submenu
        let debugMenuItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugMenuItem.submenu = DebugWindowManager.shared.createDebugMenu()
        menu.addItem(debugMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleFloatingWindow() {
        FloatingWindowManager.shared.toggleFloatingWindow()
    }

    @objc private func toggleCapture() {
        Task { @MainActor in
            if coordinator.state.isCapturing || coordinator.state == .paused {
                _ = await coordinator.stopMeeting()
            } else {
                do {
                    try await coordinator.startMeeting()
                } catch {
                    Logger.log("Failed to start meeting: \(error)", level: .error)
                    coordinator.sendNotification(
                        title: "Failed to Start",
                        body: error.localizedDescription
                    )
                }
            }
        }
    }

    @objc private func togglePause() {
        Task { @MainActor in
            if coordinator.state == .paused {
                try? await coordinator.resumeCapture()
                updateStatusIcon(capturing: true)
            } else if coordinator.state == .active {
                coordinator.pauseCapture()
                updateStatusIcon(capturing: false)
            }
        }
    }

    private func updateStatusIcon(capturing: Bool) {
        DispatchQueue.main.async { [weak self] in
            let iconName = capturing ? "waveform.circle.fill" : "waveform.circle"
            self?.statusItem.button?.image = NSImage(
                systemSymbolName: iconName,
                accessibilityDescription: "Meeting Assistant"
            )
        }
    }

    @objc private func handleOpenSettings() {
        // Open settings window
        openSettingsWindow()
    }

    @objc private func handleToggleCapture() {
        toggleCapture()
    }

    private var settingsWindow: NSWindow?

    private func openSettingsWindow() {
        // Reuse existing window if open
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Meeting Assistant Settings"
        window.setContentSize(NSSize(width: 500, height: 450))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.makeKeyAndOrderFront(nil)

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
