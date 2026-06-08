import SwiftUI
import Combine

// MARK: - Menu Bar Widget View

struct MenuBarWidgetView: View {
    @StateObject private var viewModel = MenuBarViewModel()
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Compact header (always visible)
            CompactHeaderView(
                status: viewModel.captureStatus,
                topPrediction: viewModel.topPrediction,
                audioLevel: viewModel.audioLevel,
                isExpanded: $isExpanded
            )

            // Expanded content
            if isExpanded {
                Divider()
                    .padding(.vertical, 8)

                ExpandedContentView(viewModel: viewModel)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

// MARK: - Compact Header

struct CompactHeaderView: View {
    let status: CaptureStatus
    let topPrediction: Prediction?
    let audioLevel: Float
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status row
            HStack {
                StatusIndicator(status: status)

                Spacer()

                AudioLevelIndicator(level: audioLevel)

                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Top prediction preview
            if let prediction = topPrediction {
                PredictionPreviewRow(prediction: prediction)
                    .transition(.opacity)
            } else if status == .capturing {
                Text("Listening for questions...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    let status: CaptureStatus
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
                .scaleEffect(isAnimating && status == .capturing ? 1.2 : 1.0)
                .animation(
                    status == .capturing ?
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true) :
                        .default,
                    value: isAnimating
                )

            Text(status.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Audio Level Indicator

struct AudioLevelIndicator: View {
    let level: Float
    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: index))
                    .frame(width: 3, height: barHeight(for: index))
            }
        }
        .frame(height: 12)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let threshold = Float(index + 1) / Float(barCount)
        return level >= threshold ? CGFloat(4 + index * 2) : 4
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index + 1) / Float(barCount)
        if level < threshold {
            return Color.secondary.opacity(0.3)
        }
        if index >= barCount - 1 {
            return .red
        } else if index >= barCount - 2 {
            return .orange
        }
        return .green
    }
}

// MARK: - Prediction Preview Row

struct PredictionPreviewRow: View {
    let prediction: Prediction

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ConfidenceBadge(confidence: prediction.confidence)

            VStack(alignment: .leading, spacing: 2) {
                Text(prediction.question)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                Text(prediction.category.rawValue)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }
}

// MARK: - Confidence Badge

struct ConfidenceBadge: View {
    let confidence: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 2)
                .frame(width: 24, height: 24)

            Text("\(confidence)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color)
        }
    }

    private var color: Color {
        switch confidence {
        case 8...10: return .green
        case 6...7: return .yellow
        case 4...5: return .orange
        default: return .gray
        }
    }
}

// MARK: - Expanded Content View

struct ExpandedContentView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        VStack(spacing: 12) {
            // Predictions list
            PredictionsListView(
                predictions: viewModel.predictions,
                onCopyAnswer: viewModel.copyAnswer,
                onAskQuestion: viewModel.askQuestion
            )

            Divider()

            // Live answer section
            LiveAnswerSection(viewModel: viewModel)

            Divider()

            // Quick actions
            QuickActionsBar(
                isMuted: viewModel.isMuted,
                onToggleMute: viewModel.toggleMute,
                onSettings: viewModel.openSettings,
                onExport: viewModel.exportTranscript
            )
        }
    }
}

// MARK: - Predictions List View

struct PredictionsListView: View {
    let predictions: [Prediction]
    let onCopyAnswer: (Prediction) -> Void
    let onAskQuestion: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Predicted Questions")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            if predictions.isEmpty {
                Text("No predictions yet")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(predictions.prefix(3)) { prediction in
                    PredictionRow(
                        prediction: prediction,
                        onCopy: { onCopyAnswer(prediction) },
                        onAsk: { onAskQuestion(prediction.question) }
                    )
                }
            }
        }
    }
}

// MARK: - Prediction Row

struct PredictionRow: View {
    let prediction: Prediction
    let onCopy: () -> Void
    let onAsk: () -> Void

    @State private var isHovering = false
    @State private var showAnswer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                // Confidence indicator
                RoundedRectangle(cornerRadius: 2)
                    .fill(confidenceColor)
                    .frame(width: 4, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(prediction.question)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    HStack {
                        Text(prediction.category.rawValue)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)

                        Text("•")
                            .foregroundColor(.secondary)

                        Text(prediction.confidenceLabel)
                            .font(.system(size: 9))
                            .foregroundColor(confidenceColor)
                    }
                }

                Spacer()

                // Action buttons (visible on hover)
                if isHovering {
                    HStack(spacing: 4) {
                        Button(action: { showAnswer.toggle() }) {
                            Image(systemName: showAnswer ? "eye.slash" : "eye")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Show/Hide Answer")

                        Button(action: onCopy) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Copy Answer")
                    }
                    .transition(.opacity)
                }
            }

            // Answer (expandable)
            if showAnswer {
                Text(prediction.answer)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(4)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(8)
        .background(isHovering ? Color(nsColor: .selectedControlColor).opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showAnswer)
    }

    private var confidenceColor: Color {
        switch prediction.confidence {
        case 8...10: return .green
        case 6...7: return .yellow
        case 4...5: return .orange
        default: return .gray
        }
    }
}

// MARK: - Live Answer Section

struct LiveAnswerSection: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @State private var questionText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask a Question")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            HStack {
                TextField("Type your question...", text: $questionText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(4)
                    .focused($isInputFocused)
                    .onSubmit {
                        submitQuestion()
                    }

                Button(action: submitQuestion) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(questionText.isEmpty ? .gray : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(questionText.isEmpty || viewModel.isGeneratingAnswer)
            }

            // Answer display
            if viewModel.isGeneratingAnswer {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)

                    Text(viewModel.currentAnswer.isEmpty ? "Thinking..." : viewModel.currentAnswer)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
            } else if let result = viewModel.lastAnswerResult {
                AnswerResultView(result: result)
            }
        }
    }

    private func submitQuestion() {
        guard !questionText.isEmpty else { return }
        viewModel.askQuestion(questionText)
        questionText = ""
        isInputFocused = false
    }
}

// MARK: - Answer Result View

struct AnswerResultView: View {
    let result: AnswerResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.answer)
                .font(.system(size: 11))
                .foregroundColor(.primary)

            HStack {
                Image(systemName: result.confidence.icon)
                    .font(.system(size: 9))
                    .foregroundColor(confidenceColor)

                Text(result.confidence.rawValue)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                Spacer()

                Text(result.formattedDuration)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(4)
    }

    private var confidenceColor: Color {
        switch result.confidence {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .orange
        case .none: return .gray
        }
    }
}

// MARK: - Quick Actions Bar

struct QuickActionsBar: View {
    let isMuted: Bool
    let onToggleMute: () -> Void
    let onSettings: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ActionButton(
                icon: isMuted ? "mic.slash.fill" : "mic.fill",
                label: isMuted ? "Unmute" : "Mute",
                action: onToggleMute
            )

            ActionButton(
                icon: "square.and.arrow.up",
                label: "Export",
                action: onExport
            )

            Spacer()

            ActionButton(
                icon: "gearshape",
                label: "Settings",
                action: onSettings
            )
        }
    }
}

struct ActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))

                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundColor(isHovering ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Capture Status

enum CaptureStatus {
    case idle
    case capturing
    case paused
    case error

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .capturing: return "Listening"
        case .paused: return "Paused"
        case .error: return "Error"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .gray
        case .capturing: return .green
        case .paused: return .yellow
        case .error: return .red
        }
    }
}
