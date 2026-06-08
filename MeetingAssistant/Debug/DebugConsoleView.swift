import SwiftUI

// MARK: - Debug Console View

struct DebugConsoleView: View {
    @ObservedObject private var debugMode = DebugMode.shared
    @ObservedObject private var coordinator = MeetingAssistantCoordinator.shared

    @State private var selectedTab: DebugTab = .overview
    @State private var showScenarioPicker = false
    @State private var autoScroll = true
    @State private var logFilter: DebugLogLevel?

    enum DebugTab: String, CaseIterable {
        case overview = "Overview"
        case simulation = "Simulation"
        case logs = "Logs"
        case api = "API"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Tabs
            tabBar

            Divider()

            // Content
            Group {
                switch selectedTab {
                case .overview:
                    overviewContent
                case .simulation:
                    simulationContent
                case .logs:
                    logsContent
                case .api:
                    apiContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "ladybug.fill")
                .foregroundColor(.orange)
            Text("Debug Console")
                .font(.headline)

            Spacer()

            // Debug mode toggle
            Toggle(isOn: Binding(
                get: { debugMode.isEnabled },
                set: { _ in debugMode.toggle() }
            )) {
                Text("Debug Mode")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Button(action: { debugMode.resetStats() }) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset Stats")
        }
        .padding()
        .background(debugMode.isEnabled ? Color.orange.opacity(0.1) : Color.clear)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DebugTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(tab.rawValue)
                        .font(.subheadline)
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.1) : Color.clear)
                        .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Overview Content

    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Status Section
                GroupBox("Status") {
                    VStack(spacing: 12) {
                        StatusRow(
                            label: "Debug Mode",
                            value: debugMode.isEnabled ? "Enabled" : "Disabled",
                            color: debugMode.isEnabled ? .green : .gray
                        )
                        StatusRow(
                            label: "Meeting State",
                            value: coordinator.state.rawValue,
                            color: coordinator.state.isCapturing ? .green : .gray
                        )
                        StatusRow(
                            label: "Simulation",
                            value: debugMode.isSimulating ? "Running" : "Stopped",
                            color: debugMode.isSimulating ? .blue : .gray
                        )
                    }
                }

                // Context Tokens
                GroupBox("Context") {
                    VStack(spacing: 12) {
                        if let tokenUsage = coordinator.tokenUsage {
                            TokenGauge(
                                current: tokenUsage.currentTokens,
                                target: tokenUsage.targetTokens
                            )
                            Text(tokenUsage.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("No active context")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Capture Status
                GroupBox("Capture Status") {
                    VStack(spacing: 12) {
                        CaptureStatusRow(
                            label: "Audio",
                            count: debugMode.stats.transcriptionCount,
                            icon: "waveform"
                        )
                        CaptureStatusRow(
                            label: "Screen",
                            count: debugMode.stats.screenCaptureCount,
                            icon: "rectangle.on.rectangle"
                        )
                        CaptureStatusRow(
                            label: "Predictions",
                            count: coordinator.activePredictions.count,
                            icon: "sparkles"
                        )
                    }
                }

                // Quick Stats
                GroupBox("API Stats") {
                    VStack(spacing: 12) {
                        StatRow(label: "API Calls", value: "\(debugMode.stats.apiCallCount)")
                        StatRow(label: "Last Response", value: String(format: "%.0fms", debugMode.stats.lastAPIResponseTime * 1000))
                        StatRow(label: "Avg Response", value: String(format: "%.0fms", debugMode.stats.averageAPIResponseTime * 1000))
                        StatRow(label: "Est. Tokens", value: "\(debugMode.stats.estimatedTokensUsed)")
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Simulation Content

    private var simulationContent: some View {
        VStack(spacing: 16) {
            // Scenario Picker
            GroupBox("Select Scenario") {
                VStack(spacing: 12) {
                    ForEach(DebugScenario.allScenarios) { scenario in
                        ScenarioCard(
                            scenario: scenario,
                            isSelected: debugMode.currentScenario?.id == scenario.id,
                            isRunning: debugMode.isSimulating && debugMode.currentScenario?.id == scenario.id
                        ) {
                            if debugMode.isSimulating {
                                debugMode.stopSimulation()
                            } else {
                                startScenario(scenario)
                            }
                        }
                    }
                }
            }

            // Progress
            if debugMode.isSimulating {
                GroupBox("Simulation Progress") {
                    VStack(spacing: 12) {
                        ProgressView(value: debugMode.simulationProgress)
                            .progressViewStyle(.linear)

                        HStack {
                            Text("Line \(debugMode.currentTranscriptLine)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            Text("\(Int(debugMode.simulationProgress * 100))%")
                                .font(.caption)
                                .fontWeight(.medium)
                        }

                        Button("Stop Simulation") {
                            debugMode.stopSimulation()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }

            // Settings
            GroupBox("Settings") {
                VStack(spacing: 12) {
                    HStack {
                        Text("Transcription Delay")
                        Spacer()
                        TextField("", value: Binding(
                            get: { debugMode.transcriptionDelay },
                            set: { debugMode.transcriptionDelay = $0 }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        Text("sec")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Screen Update Delay")
                        Spacer()
                        TextField("", value: Binding(
                            get: { debugMode.screenUpdateDelay },
                            set: { debugMode.screenUpdateDelay = $0 }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        Text("sec")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Logs Content

    private var logsContent: some View {
        VStack(spacing: 0) {
            // Log filters
            HStack {
                ForEach([nil, DebugLogLevel.debug, .info, .warning, .error], id: \.self) { level in
                    Button(action: { logFilter = level }) {
                        Text(level?.rawValue.capitalized ?? "All")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(logFilter == level ? Color.accentColor : Color.clear)
                            .foregroundColor(logFilter == level ? .white : .primary)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Button("Clear") {
                    debugMode.clearLogs()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Log entries
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredLogs) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
                .onChange(of: debugMode.logs.count) { _ in
                    if autoScroll, let lastLog = filteredLogs.last {
                        withAnimation {
                            proxy.scrollTo(lastLog.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var filteredLogs: [DebugLogEntry] {
        if let filter = logFilter {
            return debugMode.logs.filter { $0.level == filter }
        }
        return debugMode.logs
    }

    // MARK: - API Content

    private var apiContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // API Overview
                GroupBox("API Overview") {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Total Calls")
                            Spacer()
                            Text("\(debugMode.stats.apiCallCount)")
                                .fontWeight(.medium)
                        }

                        HStack {
                            Text("Total Time")
                            Spacer()
                            Text(String(format: "%.2fs", debugMode.stats.totalAPITime))
                                .fontWeight(.medium)
                        }

                        HStack {
                            Text("Estimated Tokens")
                            Spacer()
                            Text("\(debugMode.stats.estimatedTokensUsed)")
                                .fontWeight(.medium)
                        }
                    }
                }

                // Response Times Chart (simplified)
                GroupBox("Response Time") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Last")
                            Spacer()
                            ResponseTimeBar(time: debugMode.stats.lastAPIResponseTime)
                        }

                        HStack {
                            Text("Average")
                            Spacer()
                            ResponseTimeBar(time: debugMode.stats.averageAPIResponseTime)
                        }
                    }
                }

                // Mock API Test
                GroupBox("Test Mock API") {
                    VStack(spacing: 12) {
                        Button("Test Prediction Response") {
                            testMockAPI(type: "prediction")
                        }
                        .buttonStyle(.bordered)

                        Button("Test Summary Response") {
                            testMockAPI(type: "summary")
                        }
                        .buttonStyle(.bordered)

                        Button("Test Email Response") {
                            testMockAPI(type: "email")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func startScenario(_ scenario: DebugScenario) {
        // Connect simulation to coordinator
        debugMode.onTranscription = { text in
            MeetingContext.shared.addTranscription(text)
        }

        debugMode.onScreenUpdate = { content in
            MeetingContext.shared.updateScreenState(content, contentType: .document)
        }

        debugMode.startSimulation(scenario: scenario)
    }

    private func testMockAPI(type: String) {
        let response = debugMode.mockClaudeResponse(for: "Test \(type) request")
        debugMode.log("Mock \(type) response: \(response.prefix(100))...", level: .info)
    }
}

// MARK: - Supporting Views

struct StatusRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(value)
                    .fontWeight(.medium)
            }
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }
}

struct CaptureStatusRow: View {
    let label: String
    let count: Int
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(label)
            Spacer()
            Text("\(count)")
                .fontWeight(.medium)
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(4)
        }
    }
}

struct TokenGauge: View {
    let current: Int
    let target: Int

    var percentage: Double {
        min(1.0, Double(current) / Double(target))
    }

    var color: Color {
        if percentage > 1.0 {
            return .red
        } else if percentage > 0.8 {
            return .orange
        }
        return .green
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * min(1.0, percentage))
                }
            }
            .frame(height: 8)

            HStack {
                Text("\(current)")
                    .fontWeight(.medium)
                Spacer()
                Text("/ \(target) tokens")
                    .foregroundColor(.secondary)
            }
            .font(.caption)
        }
    }
}

struct ScenarioCard: View {
    let scenario: DebugScenario
    let isSelected: Bool
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scenario.name)
                        .font(.headline)
                    Text(scenario.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
            }
            .padding()
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct LogEntryRow: View {
    let entry: DebugLogEntry

    var levelColor: Color {
        switch entry.level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

            Text(entry.level.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(levelColor)
                .frame(width: 50, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct ResponseTimeBar: View {
    let time: TimeInterval

    var barWidth: CGFloat {
        min(200, max(20, CGFloat(time * 1000)))
    }

    var color: Color {
        if time > 1.0 {
            return .red
        } else if time > 0.5 {
            return .orange
        }
        return .green
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: barWidth, height: 16)

            Text(String(format: "%.0fms", time * 1000))
                .font(.caption)
                .monospacedDigit()
        }
    }
}
