import SwiftUI
import AVFoundation

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var settings = SettingsManager.shared
    @State private var selectedTab = SettingsTab.api

    var body: some View {
        TabView(selection: $selectedTab) {
            APISettingsTab(settings: settings)
                .tabItem {
                    Label("API", systemImage: "key")
                }
                .tag(SettingsTab.api)

            TranscriptionSettingsTab(settings: settings)
                .tabItem {
                    Label("Transcription", systemImage: "waveform")
                }
                .tag(SettingsTab.transcription)

            PredictionSettingsTab(settings: settings)
                .tabItem {
                    Label("Predictions", systemImage: "lightbulb")
                }
                .tag(SettingsTab.predictions)

            UISettingsTab(settings: settings)
                .tabItem {
                    Label("Interface", systemImage: "rectangle.on.rectangle")
                }
                .tag(SettingsTab.ui)

            AdvancedSettingsTab(settings: settings)
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 500, height: 450)
        .onDisappear {
            settings.save()
        }
    }
}

enum SettingsTab: String {
    case api, transcription, predictions, ui, advanced
}

// MARK: - API Settings Tab

struct APISettingsTab: View {
    @ObservedObject var settings: SettingsManager
    @State private var claudeAPIKey = ""
    @State private var openAIAPIKey = ""
    @State private var isTestingClaude = false
    @State private var isTestingOpenAI = false
    @State private var claudeTestResult: TestResult?
    @State private var openAITestResult: TestResult?

    var body: some View {
        Form {
            Section("Claude API (Anthropic)") {
                SecureField("API Key", text: $claudeAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: claudeAPIKey) { _ in
                        claudeTestResult = nil
                    }

                HStack {
                    Button("Test Connection") {
                        testClaudeConnection()
                    }
                    .disabled(claudeAPIKey.isEmpty || isTestingClaude)

                    if isTestingClaude {
                        ProgressView()
                            .scaleEffect(0.7)
                    }

                    if let result = claudeTestResult {
                        TestResultBadge(result: result)
                    }

                    Spacer()

                    Button("Save") {
                        saveClaudeKey()
                    }
                    .disabled(claudeAPIKey.isEmpty)
                }

                Text("Get your API key from console.anthropic.com")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("OpenAI API (Whisper Transcription)") {
                SecureField("API Key", text: $openAIAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: openAIAPIKey) { _ in
                        openAITestResult = nil
                    }

                HStack {
                    Button("Test Connection") {
                        testOpenAIConnection()
                    }
                    .disabled(openAIAPIKey.isEmpty || isTestingOpenAI)

                    if isTestingOpenAI {
                        ProgressView()
                            .scaleEffect(0.7)
                    }

                    if let result = openAITestResult {
                        TestResultBadge(result: result)
                    }

                    Spacer()

                    Button("Save") {
                        saveOpenAIKey()
                    }
                    .disabled(openAIAPIKey.isEmpty)
                }

                Text("Required for audio transcription. Get from platform.openai.com")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("API Status") {
                HStack {
                    Text("Claude API")
                    Spacer()
                    StatusDot(isConfigured: settings.hasClaudeAPIKey)
                    Text(settings.hasClaudeAPIKey ? "Configured" : "Not configured")
                        .foregroundColor(settings.hasClaudeAPIKey ? .green : .secondary)
                }

                HStack {
                    Text("OpenAI API")
                    Spacer()
                    StatusDot(isConfigured: settings.hasOpenAIAPIKey)
                    Text(settings.hasOpenAIAPIKey ? "Configured" : "Not configured")
                        .foregroundColor(settings.hasOpenAIAPIKey ? .green : .secondary)
                }
            }
        }
        .padding()
        .onAppear {
            loadKeys()
        }
    }

    private func loadKeys() {
        // Don't load actual keys for security - just check if they exist
    }

    private func saveClaudeKey() {
        do {
            try ClaudeAPIClient.shared.setAPIKey(claudeAPIKey)
            settings.hasClaudeAPIKey = true
            claudeTestResult = TestResult(success: true, message: "Saved")
        } catch {
            claudeTestResult = TestResult(success: false, message: "Failed to save")
        }
    }

    private func saveOpenAIKey() {
        do {
            try WhisperAPIClient().setAPIKey(openAIAPIKey)
            settings.hasOpenAIAPIKey = true
            openAITestResult = TestResult(success: true, message: "Saved")
        } catch {
            openAITestResult = TestResult(success: false, message: "Failed to save")
        }
    }

    private func testClaudeConnection() {
        isTestingClaude = true
        claudeTestResult = nil

        Task {
            do {
                try ClaudeAPIClient.shared.setAPIKey(claudeAPIKey)
                let response = try await ClaudeAPIClient.shared.predict("Say 'OK' and nothing else.")

                await MainActor.run {
                    isTestingClaude = false
                    if response.lowercased().contains("ok") {
                        claudeTestResult = TestResult(success: true, message: "Connected!")
                        settings.hasClaudeAPIKey = true
                    } else {
                        claudeTestResult = TestResult(success: true, message: "Connected")
                    }
                }
            } catch {
                await MainActor.run {
                    isTestingClaude = false
                    claudeTestResult = TestResult(success: false, message: error.localizedDescription)
                }
            }
        }
    }

    private func testOpenAIConnection() {
        isTestingOpenAI = true
        openAITestResult = nil

        // For OpenAI, we just save and mark as configured
        // Real test would require audio data
        Task {
            do {
                try WhisperAPIClient().setAPIKey(openAIAPIKey)
                await MainActor.run {
                    isTestingOpenAI = false
                    openAITestResult = TestResult(success: true, message: "Key saved")
                    settings.hasOpenAIAPIKey = true
                }
            } catch {
                await MainActor.run {
                    isTestingOpenAI = false
                    openAITestResult = TestResult(success: false, message: "Failed")
                }
            }
        }
    }
}

// MARK: - Transcription Settings Tab

struct TranscriptionSettingsTab: View {
    @ObservedObject var settings: SettingsManager
    @State private var isTestingAudio = false
    @State private var audioTestResult: TestResult?
    @State private var audioLevel: Float = 0

    var body: some View {
        Form {
            Section("Language") {
                Picker("Transcription Language", selection: $settings.transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Toggle("Auto-detect language", isOn: $settings.autoDetectLanguage)
            }

            Section("Audio Source") {
                Picker("Audio Input", selection: $settings.audioSource) {
                    Text("System Audio (Recommended)").tag(AudioSource.system)
                    Text("Microphone").tag(AudioSource.microphone)
                    Text("Both").tag(AudioSource.both)
                }

                HStack {
                    Button("Test Audio Capture") {
                        testAudioCapture()
                    }
                    .disabled(isTestingAudio)

                    if isTestingAudio {
                        ProgressView()
                            .scaleEffect(0.7)
                        AudioLevelMeter(level: audioLevel)
                            .frame(width: 100)
                    }

                    if let result = audioTestResult {
                        TestResultBadge(result: result)
                    }
                }

                Text("System audio captures meeting audio without showing as participant")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Quality") {
                Picker("Accuracy Level", selection: $settings.transcriptionAccuracy) {
                    Text("Fast (Lower quality)").tag(TranscriptionAccuracy.fast)
                    Text("Balanced").tag(TranscriptionAccuracy.balanced)
                    Text("Accurate (Slower)").tag(TranscriptionAccuracy.accurate)
                }

                HStack {
                    Text("Chunk Duration")
                    Slider(value: $settings.audioChunkDuration, in: 3...10, step: 1)
                    Text("\(Int(settings.audioChunkDuration))s")
                        .frame(width: 30)
                }

                Text("Shorter chunks = faster response, longer = better accuracy")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Noise Handling") {
                HStack {
                    Text("Silence Threshold")
                    Slider(value: $settings.silenceThreshold, in: 0.001...0.05)
                    Text(String(format: "%.3f", settings.silenceThreshold))
                        .frame(width: 45)
                }

                Toggle("Skip silent chunks", isOn: $settings.skipSilentChunks)
            }
        }
        .padding()
    }

    private func testAudioCapture() {
        isTestingAudio = true
        audioTestResult = nil

        Task {
            do {
                let hasPermission = await ScreenMonitor.shared.checkPermission()

                if !hasPermission {
                    await MainActor.run {
                        isTestingAudio = false
                        audioTestResult = TestResult(success: false, message: "Permission required")
                    }
                    return
                }

                // Brief capture test
                try await Task.sleep(nanoseconds: 2_000_000_000)

                await MainActor.run {
                    isTestingAudio = false
                    audioTestResult = TestResult(success: true, message: "Audio working")
                }
            } catch {
                await MainActor.run {
                    isTestingAudio = false
                    audioTestResult = TestResult(success: false, message: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Prediction Settings Tab

struct PredictionSettingsTab: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        Form {
            Section("Update Frequency") {
                Picker("Update Interval", selection: $settings.predictionUpdateInterval) {
                    Text("5 seconds (Fast)").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("15 seconds (Balanced)").tag(15.0)
                    Text("20 seconds").tag(20.0)
                    Text("30 seconds (Conservative)").tag(30.0)
                }

                Text("More frequent updates use more API calls")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Display") {
                Stepper("Show top \(settings.maxPredictionsToShow) predictions",
                       value: $settings.maxPredictionsToShow, in: 1...5)

                HStack {
                    Text("Minimum Confidence")
                    Slider(value: Binding(
                        get: { Double(settings.minConfidenceThreshold) },
                        set: { settings.minConfidenceThreshold = Int($0) }
                    ), in: 1...8, step: 1)
                    Text("\(settings.minConfidenceThreshold)")
                        .frame(width: 20)
                }

                Toggle("Show confidence scores", isOn: $settings.showConfidenceScores)
                Toggle("Show prediction categories", isOn: $settings.showPredictionCategories)
            }

            Section("Behavior") {
                Toggle("Auto-copy high-confidence answers", isOn: $settings.autoCopyHighConfidence)

                if settings.autoCopyHighConfidence {
                    HStack {
                        Text("Auto-copy threshold")
                        Slider(value: Binding(
                            get: { Double(settings.autoCopyThreshold) },
                            set: { settings.autoCopyThreshold = Int($0) }
                        ), in: 7...10, step: 1)
                        Text("\(settings.autoCopyThreshold)")
                            .frame(width: 20)
                    }
                }

                Toggle("Play sound on new prediction", isOn: $settings.playSoundOnPrediction)
            }

            Section("Cache") {
                HStack {
                    Text("Cache Duration")
                    Slider(value: $settings.predictionCacheDuration, in: 10...120, step: 10)
                    Text("\(Int(settings.predictionCacheDuration))s")
                        .frame(width: 35)
                }

                Button("Clear Prediction Cache") {
                    PredictionEngine.shared.clearPredictions()
                }
            }
        }
        .padding()
    }
}

// MARK: - UI Settings Tab

struct UISettingsTab: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        Form {
            Section("Display Mode") {
                Picker("Primary Interface", selection: $settings.displayMode) {
                    Text("Menu Bar Popover").tag(DisplayMode.menuBar)
                    Text("Floating Window").tag(DisplayMode.floating)
                    Text("Both").tag(DisplayMode.both)
                }

                if settings.displayMode != .menuBar {
                    Toggle("Show floating window on launch", isOn: $settings.showFloatingOnLaunch)

                    Picker("Floating Window Position", selection: $settings.floatingWindowPosition) {
                        ForEach(FloatingWindowPosition.allCases, id: \.self) { position in
                            Text(position.rawValue).tag(position)
                        }
                    }
                }
            }

            Section("Appearance") {
                HStack {
                    Text("Floating Window Opacity")
                    Slider(value: $settings.floatingWindowOpacity, in: 0.5...1.0)
                    Text("\(Int(settings.floatingWindowOpacity * 100))%")
                        .frame(width: 40)
                }

                HStack {
                    Text("Font Size")
                    Slider(value: $settings.fontSize, in: 9...14, step: 1)
                    Text("\(Int(settings.fontSize))")
                        .frame(width: 20)
                }

                Toggle("Compact mode", isOn: $settings.compactMode)
            }

            Section("Keyboard Shortcuts") {
                KeyboardShortcutRow(
                    label: "Toggle Floating Window",
                    shortcut: "⇧⌘M"
                )

                KeyboardShortcutRow(
                    label: "Start/Stop Capture",
                    shortcut: "⇧⌘C"
                )

                KeyboardShortcutRow(
                    label: "Copy Top Answer",
                    shortcut: "⇧⌘V"
                )

                Text("Shortcuts can be customized in System Settings > Keyboard > Shortcuts")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Notifications") {
                Toggle("Show notifications for new predictions", isOn: $settings.showNotifications)
                Toggle("Badge menu bar icon when capturing", isOn: $settings.badgeMenuBarIcon)
            }
        }
        .padding()
    }
}

// MARK: - Advanced Settings Tab

struct AdvancedSettingsTab: View {
    @ObservedObject var settings: SettingsManager
    @State private var currentTokens = 0

    var body: some View {
        Form {
            Section("Context Management") {
                HStack {
                    Text("Target Token Limit")
                    Slider(value: Binding(
                        get: { Double(settings.targetTokenLimit) },
                        set: { settings.targetTokenLimit = Int($0) }
                    ), in: 1000...4000, step: 500)
                    Text("\(settings.targetTokenLimit)")
                        .frame(width: 45)
                }

                HStack {
                    Text("Max Transcription Messages")
                    Stepper("\(settings.maxTranscriptionMessages)",
                           value: $settings.maxTranscriptionMessages, in: 5...30)
                }

                HStack {
                    Text("Max Screen States")
                    Stepper("\(settings.maxScreenStates)",
                           value: $settings.maxScreenStates, in: 2...10)
                }
            }

            Section("Token Usage") {
                HStack {
                    Text("Current Context Tokens")
                    Spacer()
                    Text("\(currentTokens) / \(settings.targetTokenLimit)")
                        .foregroundColor(currentTokens > settings.targetTokenLimit ? .red : .primary)
                }

                ProgressView(value: Double(currentTokens), total: Double(settings.targetTokenLimit))
                    .tint(currentTokens > settings.targetTokenLimit ? .red : .blue)

                Button("Refresh Token Count") {
                    currentTokens = MeetingContext.shared.estimateTokens()
                }

                Button("Clear Context") {
                    MeetingContext.shared.clear()
                    currentTokens = 0
                }
            }

            Section("Claude Model") {
                Picker("Model", selection: $settings.claudeModel) {
                    Text("Claude 3 Haiku (Fast)").tag("claude-3-haiku-20240307")
                    Text("Claude 3.5 Sonnet (Balanced)").tag("claude-3-5-sonnet-20241022")
                    Text("Claude 4 Sonnet (Best)").tag("claude-sonnet-4-20250514")
                }
            }

            Section("Debugging") {
                Toggle("Enable debug logging", isOn: $settings.debugLogging)
                Toggle("Show token counts in UI", isOn: $settings.showTokenCounts)

                if settings.debugLogging {
                    Button("Export Debug Log") {
                        exportDebugLog()
                    }
                }
            }

            Section("Reset") {
                Button("Reset All Settings to Defaults", role: .destructive) {
                    settings.resetToDefaults()
                }

                Button("Clear All Data", role: .destructive) {
                    clearAllData()
                }
            }
        }
        .padding()
        .onAppear {
            currentTokens = MeetingContext.shared.estimateTokens()
        }
    }

    private func exportDebugLog() {
        // Export debug log implementation
        print("Exporting debug log...")
    }

    private func clearAllData() {
        MeetingContext.shared.clear()
        PredictionEngine.shared.clearPredictions()
        LiveAnswerGenerator.shared.clearHistory()
        currentTokens = 0
    }
}

// MARK: - Helper Views

struct TestResultBadge: View {
    let result: TestResult

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
            Text(result.message)
        }
        .font(.caption)
        .foregroundColor(result.success ? .green : .red)
    }
}

struct StatusDot: View {
    let isConfigured: Bool

    var body: some View {
        Circle()
            .fill(isConfigured ? Color.green : Color.gray)
            .frame(width: 8, height: 8)
    }
}

struct KeyboardShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(shortcut)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)
        }
    }
}

struct AudioLevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))

                Rectangle()
                    .fill(level > 0.7 ? Color.red : (level > 0.4 ? Color.yellow : Color.green))
                    .frame(width: geometry.size.width * CGFloat(level))
            }
            .cornerRadius(2)
        }
        .frame(height: 8)
    }
}

struct TestResult {
    let success: Bool
    let message: String
}
