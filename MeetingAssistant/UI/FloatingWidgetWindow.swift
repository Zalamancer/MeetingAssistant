import Cocoa
import SwiftUI
import Combine

// MARK: - Floating Widget Window

final class FloatingWidgetWindow: NSPanel {
    private var floatingView: NSHostingView<FloatingWidgetContent>?
    private let viewModel = FloatingWidgetViewModel()

    // Settings
    var windowOpacity: CGFloat = 0.95 {
        didSet { alphaValue = windowOpacity }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        setupWindow()
        setupContent()
        positionWindow()
    }

    private func setupWindow() {
        // Window behavior
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        // Appearance
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = .clear
        isOpaque = false
        alphaValue = windowOpacity
        hasShadow = true

        // Size constraints
        minSize = NSSize(width: 250, height: 300)
        maxSize = NSSize(width: 500, height: 600)

        // Visual effect background
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true

        contentView = visualEffect
    }

    private func setupContent() {
        let swiftUIContent = FloatingWidgetContent(viewModel: viewModel)
        floatingView = NSHostingView(rootView: swiftUIContent)
        floatingView?.translatesAutoresizingMaskIntoConstraints = false

        if let visualEffect = contentView as? NSVisualEffectView,
           let hostingView = floatingView {
            visualEffect.addSubview(hostingView)

            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
                hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
                hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor)
            ])
        }
    }

    private func positionWindow() {
        // Position in top-right corner
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = frame
            let x = screenFrame.maxX - windowFrame.width - 20
            let y = screenFrame.maxY - windowFrame.height - 20
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // MARK: - Public Methods

    func show() {
        viewModel.startUpdating()
        orderFront(nil)
        makeKey()
    }

    func hide() {
        viewModel.stopUpdating()
        orderOut(nil)
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func updateSettings(opacity: CGFloat? = nil, fontSize: CGFloat? = nil) {
        if let opacity = opacity {
            windowOpacity = opacity
        }
        if let fontSize = fontSize {
            viewModel.fontSize = fontSize
        }
    }

    // Save position for next launch
    func savePosition() {
        let origin = frame.origin
        UserDefaults.standard.set(origin.x, forKey: "floatingWindowX")
        UserDefaults.standard.set(origin.y, forKey: "floatingWindowY")
    }

    func restorePosition() {
        let x = UserDefaults.standard.double(forKey: "floatingWindowX")
        let y = UserDefaults.standard.double(forKey: "floatingWindowY")
        if x != 0 || y != 0 {
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    override func close() {
        savePosition()
        super.close()
    }
}

// MARK: - Floating Widget View Model

@MainActor
final class FloatingWidgetViewModel: ObservableObject {
    @Published var transcriptLines: [String] = []
    @Published var predictions: [Prediction] = []
    @Published var contextSummary: String = ""
    @Published var isCapturing = false
    @Published var audioLevel: Float = 0
    @Published var fontSize: CGFloat = 11

    private var cancellables = Set<AnyCancellable>()
    private let coordinator = MeetingAssistantCoordinator.shared
    private let context = MeetingContext.shared

    func startUpdating() {
        // Bind to coordinator's published properties
        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isCapturing = state.isCapturing
            }
            .store(in: &cancellables)

        coordinator.$activePredictions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] predictions in
                self?.predictions = Array(predictions.prefix(2))
            }
            .store(in: &cancellables)

        coordinator.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }
            .store(in: &cancellables)

        coordinator.$lastTranscription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.addTranscriptLine(text)
            }
            .store(in: &cancellables)

        refresh()
    }

    func stopUpdating() {
        cancellables.removeAll()
    }

    private func refresh() {
        isCapturing = coordinator.state.isCapturing
        predictions = Array(coordinator.activePredictions.prefix(2))

        // Build context summary
        let fullContext = context.getFullContext()
        let topics = fullContext.topics.prefix(3).joined(separator: ", ")
        let participants = fullContext.metadata.participants.prefix(3).joined(separator: ", ")

        var summary = ""
        if !topics.isEmpty {
            summary += "Topics: \(topics)"
        }
        if !participants.isEmpty {
            if !summary.isEmpty { summary += "\n" }
            summary += "Participants: \(participants)"
        }
        contextSummary = summary.isEmpty ? "No context yet" : summary
    }

    private func addTranscriptLine(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        transcriptLines.append(trimmed)

        // Keep only last 3 lines
        if transcriptLines.count > 3 {
            transcriptLines.removeFirst()
        }
    }

    func toggleCapture() {
        Task {
            if coordinator.state.isCapturing || coordinator.state == .paused {
                _ = await coordinator.stopMeeting()
            } else {
                try? await coordinator.startMeeting()
            }
        }
    }
}

// MARK: - Floating Widget SwiftUI Content

struct FloatingWidgetContent: View {
    @ObservedObject var viewModel: FloatingWidgetViewModel
    @State private var isSettingsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with drag handle
            HeaderBar(
                isCapturing: viewModel.isCapturing,
                audioLevel: viewModel.audioLevel,
                onToggleCapture: viewModel.toggleCapture,
                isSettingsExpanded: $isSettingsExpanded
            )

            Divider()
                .opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Live transcription
                    TranscriptionSection(
                        lines: viewModel.transcriptLines,
                        fontSize: viewModel.fontSize
                    )

                    // Predictions
                    PredictionsSection(
                        predictions: viewModel.predictions,
                        fontSize: viewModel.fontSize
                    )

                    // Context summary
                    ContextSection(
                        summary: viewModel.contextSummary,
                        fontSize: viewModel.fontSize
                    )
                }
                .padding(12)
            }

            // Settings panel (collapsible)
            if isSettingsExpanded {
                SettingsPanel(viewModel: viewModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSettingsExpanded)
    }
}

// MARK: - Header Bar

struct HeaderBar: View {
    let isCapturing: Bool
    let audioLevel: Float
    let onToggleCapture: () -> Void
    @Binding var isSettingsExpanded: Bool

    var body: some View {
        HStack {
            // Status
            HStack(spacing: 6) {
                Circle()
                    .fill(isCapturing ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)

                Text(isCapturing ? "Live" : "Paused")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer()

            // Mini audio meter
            if isCapturing {
                MiniAudioMeter(level: audioLevel)
            }

            Spacer()

            // Controls
            HStack(spacing: 8) {
                Button(action: onToggleCapture) {
                    Image(systemName: isCapturing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)

                Button(action: { isSettingsExpanded.toggle() }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.1))
    }
}

// MARK: - Mini Audio Meter

struct MiniAudioMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: i))
                    .frame(width: 2, height: 8)
            }
        }
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index + 1) / 8.0
        if level < threshold {
            return Color.white.opacity(0.2)
        }
        if index >= 6 { return .red }
        if index >= 4 { return .yellow }
        return .green
    }
}

// MARK: - Transcription Section

struct TranscriptionSection: View {
    let lines: [String]
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "TRANSCRIPTION", icon: "waveform")

            if lines.isEmpty {
                Text("Waiting for audio...")
                    .font(.system(size: fontSize))
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: fontSize))
                        .foregroundColor(index == lines.count - 1 ? .primary : .secondary)
                        .lineLimit(2)
                        .opacity(Double(index + 1) / Double(lines.count))
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Predictions Section

struct PredictionsSection: View {
    let predictions: [Prediction]
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "PREDICTIONS", icon: "lightbulb")

            if predictions.isEmpty {
                Text("No predictions yet")
                    .font(.system(size: fontSize))
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(predictions) { prediction in
                    CompactPredictionRow(prediction: prediction, fontSize: fontSize)
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.1))
        .cornerRadius(8)
    }
}

struct CompactPredictionRow: View {
    let prediction: Prediction
    let fontSize: CGFloat
    @State private var showAnswer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                // Confidence badge
                Text("\(prediction.confidence)")
                    .font(.system(size: fontSize - 2, weight: .bold))
                    .foregroundColor(confidenceColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(prediction.question)
                        .font(.system(size: fontSize))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }

                Spacer()

                Button(action: { showAnswer.toggle() }) {
                    Image(systemName: showAnswer ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if showAnswer {
                Text(prediction.answer)
                    .font(.system(size: fontSize - 1))
                    .foregroundColor(.secondary)
                    .padding(.leading, 22)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showAnswer)
    }

    private var confidenceColor: Color {
        switch prediction.confidence {
        case 8...10: return .green
        case 6...7: return .yellow
        default: return .orange
        }
    }
}

// MARK: - Context Section

struct ContextSection: View {
    let summary: String
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "CONTEXT", icon: "doc.text")

            Text(summary)
                .font(.system(size: fontSize))
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding(8)
        .background(Color.black.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))

            Text(title)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(.secondary)
    }
}

// MARK: - Settings Panel

struct SettingsPanel: View {
    @ObservedObject var viewModel: FloatingWidgetViewModel
    @State private var opacity: Double = 0.95
    @State private var fontSize: Double = 11

    var body: some View {
        VStack(spacing: 8) {
            Divider()
                .opacity(0.5)

            HStack {
                Text("Opacity")
                    .font(.system(size: 10))
                Slider(value: $opacity, in: 0.5...1.0)
                    .frame(width: 80)
            }

            HStack {
                Text("Font Size")
                    .font(.system(size: 10))
                Slider(value: $fontSize, in: 9...14, step: 1)
                    .frame(width: 80)
                Text("\(Int(fontSize))")
                    .font(.system(size: 10))
                    .frame(width: 20)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.1))
        .onChange(of: fontSize) { newValue in
            viewModel.fontSize = CGFloat(newValue)
        }
    }
}
