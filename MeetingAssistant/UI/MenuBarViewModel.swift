import SwiftUI
import Combine
import AppKit

// MARK: - Menu Bar View Model

@MainActor
final class MenuBarViewModel: ObservableObject {
    // Published state
    @Published var captureStatus: CaptureStatus = .idle
    @Published var predictions: [Prediction] = []
    @Published var audioLevel: Float = 0
    @Published var currentAnswer: String = ""
    @Published var lastAnswerResult: AnswerResult?
    @Published var isGeneratingAnswer = false
    @Published var isMuted = false
    @Published var transcriptPreview: String = ""
    @Published var errorMessage: String?

    // Computed
    var topPrediction: Prediction? {
        predictions.first
    }

    // Dependencies - use coordinator as single source of truth
    private let coordinator = MeetingAssistantCoordinator.shared
    private let answerGenerator = LiveAnswerGenerator.shared

    // Combine
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupBindings()
    }

    // MARK: - Setup

    private func setupBindings() {
        // Bind to coordinator's published properties
        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateCaptureStatus(from: state)
            }
            .store(in: &cancellables)

        coordinator.$activePredictions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] predictions in
                withAnimation(.easeInOut(duration: 0.3)) {
                    self?.predictions = predictions
                }
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
                self?.transcriptPreview = String(text.suffix(100))
            }
            .store(in: &cancellables)

        coordinator.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.errorMessage = error
            }
            .store(in: &cancellables)
    }

    private func updateCaptureStatus(from state: MeetingState) {
        switch state {
        case .idle, .stopping:
            captureStatus = .idle
        case .starting:
            captureStatus = .idle
        case .active:
            captureStatus = .capturing
        case .paused:
            captureStatus = .paused
        }
    }

    // MARK: - Actions

    func startCapture() {
        Task {
            do {
                try await coordinator.startMeeting()
            } catch {
                errorMessage = error.localizedDescription
                print("Failed to start capture: \(error)")
            }
        }
    }

    func stopCapture() {
        Task {
            _ = await coordinator.stopMeeting()
        }
    }

    func toggleCapture() {
        if coordinator.state.isCapturing || coordinator.state == .paused {
            stopCapture()
        } else {
            startCapture()
        }
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            coordinator.pauseCapture()
        } else {
            Task {
                try? await coordinator.resumeCapture()
            }
        }
    }

    func askQuestion(_ question: String) {
        isGeneratingAnswer = true
        currentAnswer = ""
        lastAnswerResult = nil

        Task {
            await answerGenerator.generateAnswer(
                for: question,
                onToken: { [weak self] token in
                    Task { @MainActor in
                        self?.currentAnswer += token
                    }
                },
                onComplete: { [weak self] result in
                    Task { @MainActor in
                        self?.isGeneratingAnswer = false
                        self?.lastAnswerResult = result
                    }
                }
            )
        }
    }

    func copyAnswer(_ prediction: Prediction) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prediction.answer, forType: .string)
    }

    func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    func exportTranscript() {
        let transcript = coordinator.exportTranscript()

        guard !transcript.isEmpty else {
            print("No transcript to export")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "meeting-transcript-\(formattedDate()).txt"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try transcript.write(to: url, atomically: true, encoding: .utf8)
                print("Transcript exported to \(url.path)")
            } catch {
                print("Failed to export: \(error)")
            }
        }
    }

    func refreshPredictions() {
        Task {
            await coordinator.refreshPredictions()
        }
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let toggleCapture = Notification.Name("toggleCapture")
}

// MARK: - Preview Provider

struct MenuBarWidgetView_Previews: PreviewProvider {
    static var previews: some View {
        MenuBarWidgetView()
            .frame(width: 320, height: 400)
    }
}
