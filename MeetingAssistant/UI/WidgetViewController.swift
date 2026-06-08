import Cocoa

final class WidgetViewController: NSViewController {
    // UI Elements
    private let statusLabel = NSTextField(labelWithString: "Ready to capture")
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "")
    private let levelIndicator = NSLevelIndicator()
    private let actionButton = NSButton(title: "Start Capture", target: nil, action: nil)
    private let settingsButton = NSButton(title: "⚙", target: nil, action: nil)

    // Services
    private let captureManager = MeetingCaptureManager.shared
    private let claude = ClaudeAPIClient.shared
    private var isCapturing = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupCallbacks()
        claude.configureForMeetings()
    }

    private func setupUI() {
        view.wantsLayer = true

        // Status label
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Audio level indicator
        levelIndicator.minValue = 0
        levelIndicator.maxValue = 1
        levelIndicator.warningValue = 0.7
        levelIndicator.criticalValue = 0.9
        levelIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(levelIndicator)

        // Transcript label
        transcriptLabel.font = .systemFont(ofSize: 11)
        transcriptLabel.textColor = .secondaryLabelColor
        transcriptLabel.alignment = .left
        transcriptLabel.maximumNumberOfLines = 5
        transcriptLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcriptLabel)

        // Action button
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(actionButtonClicked)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionButton)

        // Settings button
        settingsButton.bezelStyle = .inline
        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonClicked)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),

            levelIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            levelIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            levelIndicator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            levelIndicator.heightAnchor.constraint(equalToConstant: 16),

            transcriptLabel.topAnchor.constraint(equalTo: levelIndicator.bottomAnchor, constant: 12),
            transcriptLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            transcriptLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            actionButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            actionButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            settingsButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            settingsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])
    }

    private func setupCallbacks() {
        captureManager.onStatusUpdate = { [weak self] status in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = status
            }
        }

        captureManager.onTranscript = { [weak self] text in
            DispatchQueue.main.async {
                let preview = String(text.prefix(200))
                self?.transcriptLabel.stringValue = preview
            }
        }

        AudioMonitor.shared.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.levelIndicator.doubleValue = Double(min(level * 10, 1.0))
            }
        }
    }

    @objc private func actionButtonClicked() {
        if isCapturing {
            stopCapture()
        } else {
            startCapture()
        }
    }

    @objc private func settingsButtonClicked() {
        showSettingsMenu()
    }

    private func startCapture() {
        isCapturing = true
        statusLabel.stringValue = "Starting..."
        actionButton.title = "Stop Capture"
        transcriptLabel.stringValue = ""

        Task {
            do {
                try await captureManager.startCapture()
                await MainActor.run {
                    statusLabel.stringValue = "Capturing audio & screen..."
                }
            } catch {
                await MainActor.run {
                    statusLabel.stringValue = "Error: \(error.localizedDescription)"
                    transcriptLabel.stringValue = getPermissionHint(for: error)
                    isCapturing = false
                    actionButton.title = "Start Capture"
                }
            }
        }
    }

    private func stopCapture() {
        isCapturing = false
        actionButton.title = "Start Capture"
        statusLabel.stringValue = "Generating summary..."

        Task {
            await captureManager.stopCapture()

            do {
                let summary = try await captureManager.getMeetingSummary()
                await MainActor.run {
                    statusLabel.stringValue = "Meeting ended"
                    transcriptLabel.stringValue = summary
                }
            } catch {
                await MainActor.run {
                    statusLabel.stringValue = "Capture complete"
                    let transcript = captureManager.transcriptBuffer.getFullTranscript()
                    transcriptLabel.stringValue = transcript.isEmpty ? "No audio captured" : String(transcript.suffix(200))
                }
            }
        }
    }

    private func getPermissionHint(for error: Error) -> String {
        if let audioError = error as? AudioMonitorError {
            switch audioError {
            case .permissionDenied:
                return "Enable Screen Recording in System Settings > Privacy & Security"
            default:
                return error.localizedDescription
            }
        }
        if let screenError = error as? ScreenMonitorError {
            switch screenError {
            case .permissionDenied:
                return "Enable Screen Recording in System Settings > Privacy & Security"
            default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func showSettingsMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "Set Claude API Key...", action: #selector(setClaudeKey), keyEquivalent: "")
        menu.addItem(withTitle: "Set OpenAI API Key...", action: #selector(setOpenAIKey), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Export Transcript...", action: #selector(exportTranscript), keyEquivalent: "")
        menu.addItem(withTitle: "Get Action Items", action: #selector(getActionItems), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Clear Buffers", action: #selector(clearBuffers), keyEquivalent: "")

        for item in menu.items {
            item.target = self
        }

        let location = NSPoint(x: settingsButton.frame.minX, y: settingsButton.frame.minY)
        menu.popUp(positioning: nil, at: location, in: view)
    }

    @objc private func setClaudeKey() {
        showAPIKeyDialog(
            title: "Claude API Key",
            placeholder: "sk-ant-...",
            onSave: { [weak self] key in
                try self?.claude.setAPIKey(key)
            }
        )
    }

    @objc private func setOpenAIKey() {
        showAPIKeyDialog(
            title: "OpenAI API Key (for Whisper)",
            placeholder: "sk-...",
            onSave: { key in
                try WhisperAPIClient().setAPIKey(key)
            }
        )
    }

    @objc private func exportTranscript() {
        let transcript = captureManager.exportTranscript()

        guard !transcript.isEmpty else {
            statusLabel.stringValue = "No transcript to export"
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "meeting-transcript.txt"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try transcript.write(to: url, atomically: true, encoding: .utf8)
                statusLabel.stringValue = "Transcript exported"
            } catch {
                statusLabel.stringValue = "Export failed"
            }
        }
    }

    @objc private func getActionItems() {
        statusLabel.stringValue = "Extracting action items..."

        Task {
            do {
                let items = try await captureManager.getActionItems()
                await MainActor.run {
                    statusLabel.stringValue = "Action items:"
                    transcriptLabel.stringValue = items
                }
            } catch {
                await MainActor.run {
                    statusLabel.stringValue = "Failed to extract"
                    transcriptLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func clearBuffers() {
        captureManager.clearBuffers()
        transcriptLabel.stringValue = ""
        statusLabel.stringValue = "Buffers cleared"
        levelIndicator.doubleValue = 0
    }

    private func showAPIKeyDialog(title: String, placeholder: String, onSave: @escaping (String) throws -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Stored securely in macOS Keychain."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = placeholder
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                do {
                    try onSave(key)
                    statusLabel.stringValue = "API key saved"
                } catch {
                    statusLabel.stringValue = "Failed to save key"
                }
            }
        }
    }
}
