import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Debug Window Manager

final class DebugWindowManager {
    static let shared = DebugWindowManager()

    private var debugWindow: NSWindow?
    private var eventMonitor: Any?

    private init() {
        setupGlobalShortcuts()
    }

    // MARK: - Window Management

    @MainActor
    func showDebugConsole() {
        if let window = debugWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let consoleView = DebugConsoleView()
        let hostingController = NSHostingController(rootView: consoleView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Debug Console"
        window.setContentSize(NSSize(width: 550, height: 500))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 400, height: 300)
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Position in bottom right
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowSize = window.frame.size
            let newOrigin = NSPoint(
                x: screenRect.maxX - windowSize.width - 20,
                y: screenRect.minY + 20
            )
            window.setFrameOrigin(newOrigin)
        }

        debugWindow = window
        NSApp.activate(ignoringOtherApps: true)

        DebugMode.shared.log("Debug console opened", level: .info)
    }

    @MainActor
    func hideDebugConsole() {
        debugWindow?.close()
        debugWindow = nil
    }

    @MainActor
    func toggleDebugConsole() {
        if debugWindow?.isVisible == true {
            hideDebugConsole()
        } else {
            showDebugConsole()
        }
    }

    // MARK: - Global Shortcuts

    private func setupGlobalShortcuts() {
        // ⇧⌘D - Toggle Debug Console
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Check for Shift+Command+D
            if event.modifierFlags.contains([.shift, .command]) && event.keyCode == 2 {  // 'D' key
                Task { @MainActor in
                    self?.toggleDebugConsole()
                }
            }

            // Check for ⌥⌘D - Toggle Debug Mode
            if event.modifierFlags.contains([.option, .command]) && event.keyCode == 2 {  // 'D' key
                DebugMode.shared.toggle()
            }
        }

        // Also add local monitor for when app is focused
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⇧⌘D - Toggle Debug Console
            if event.modifierFlags.contains([.shift, .command]) && event.keyCode == 2 {
                Task { @MainActor in
                    self?.toggleDebugConsole()
                }
                return nil
            }

            // ⌥⌘D - Toggle Debug Mode
            if event.modifierFlags.contains([.option, .command]) && event.keyCode == 2 {
                DebugMode.shared.toggle()
                return nil
            }

            return event
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Debug Mode Integration

extension DebugMode {
    /// Wire up debug mode to replace real audio/screen with simulated data
    func wireUpToCoordinator() {
        // When simulation sends transcription, add to context
        onTranscription = { text in
            MeetingContext.shared.addTranscription(text)
        }

        // When simulation updates screen, add to context
        onScreenUpdate = { content in
            MeetingContext.shared.updateScreenState(content, contentType: .document)
        }

        log("Debug mode wired to coordinator", level: .info)
    }

    /// Start a quick test session with the tech team scenario
    func startQuickTest() {
        if !isEnabled {
            enable()
        }

        wireUpToCoordinator()
        startSimulation(scenario: .techTeamMeeting)
    }
}

// MARK: - Debug Menu Items

extension DebugWindowManager {
    @MainActor
    func createDebugMenu() -> NSMenu {
        let menu = NSMenu(title: "Debug")

        let toggleDebugItem = NSMenuItem(
            title: DebugMode.shared.isEnabled ? "Disable Debug Mode" : "Enable Debug Mode",
            action: #selector(toggleDebugMode),
            keyEquivalent: "d"
        )
        toggleDebugItem.keyEquivalentModifierMask = [.option, .command]
        toggleDebugItem.target = self
        menu.addItem(toggleDebugItem)

        let consoleItem = NSMenuItem(
            title: "Show Debug Console",
            action: #selector(showConsole),
            keyEquivalent: "d"
        )
        consoleItem.keyEquivalentModifierMask = [.shift, .command]
        consoleItem.target = self
        menu.addItem(consoleItem)

        menu.addItem(NSMenuItem.separator())

        // Simulation submenu
        let simMenu = NSMenu(title: "Simulations")

        for scenario in DebugScenario.allScenarios {
            let item = NSMenuItem(
                title: scenario.name,
                action: #selector(startScenario(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = scenario
            simMenu.addItem(item)
        }

        let simMenuItem = NSMenuItem(title: "Start Simulation", action: nil, keyEquivalent: "")
        simMenuItem.submenu = simMenu
        menu.addItem(simMenuItem)

        let stopSimItem = NSMenuItem(
            title: "Stop Simulation",
            action: #selector(stopSimulation),
            keyEquivalent: ""
        )
        stopSimItem.target = self
        stopSimItem.isEnabled = DebugMode.shared.isSimulating
        menu.addItem(stopSimItem)

        menu.addItem(NSMenuItem.separator())

        let resetItem = NSMenuItem(
            title: "Reset Stats",
            action: #selector(resetStats),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        let clearLogsItem = NSMenuItem(
            title: "Clear Logs",
            action: #selector(clearLogs),
            keyEquivalent: ""
        )
        clearLogsItem.target = self
        menu.addItem(clearLogsItem)

        return menu
    }

    @objc private func toggleDebugMode() {
        DebugMode.shared.toggle()
    }

    @objc private func showConsole() {
        Task { @MainActor in
            showDebugConsole()
        }
    }

    @objc private func startScenario(_ sender: NSMenuItem) {
        guard let scenario = sender.representedObject as? DebugScenario else { return }
        if !DebugMode.shared.isEnabled {
            DebugMode.shared.enable()
        }
        DebugMode.shared.wireUpToCoordinator()
        DebugMode.shared.startSimulation(scenario: scenario)
    }

    @objc private func stopSimulation() {
        DebugMode.shared.stopSimulation()
    }

    @objc private func resetStats() {
        DebugMode.shared.resetStats()
    }

    @objc private func clearLogs() {
        DebugMode.shared.clearLogs()
    }
}
