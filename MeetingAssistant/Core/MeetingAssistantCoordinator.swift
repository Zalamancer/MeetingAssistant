import Foundation
import Combine
import AppKit

// MARK: - Meeting Assistant Coordinator

@MainActor
final class MeetingAssistantCoordinator: ObservableObject {
    static let shared = MeetingAssistantCoordinator()

    // MARK: - Components

    let screenMonitor = ScreenMonitor.shared
    private let audioMonitor = AudioMonitor.shared
    let context = MeetingContext.shared
    let predictionEngine = PredictionEngine.shared
    let answerGenerator = LiveAnswerGenerator.shared
    private let settings = SettingsManager.shared

    // MARK: - Published State

    @Published private(set) var state: MeetingState = .idle
    @Published private(set) var currentMeeting: MeetingInfo?
    @Published private(set) var activePredictions: [Prediction] = []
    @Published private(set) var lastTranscription: String = ""
    @Published private(set) var lastScreenText: String = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var tokenUsage: TokenBudgetStatus?

    // MARK: - Internal State (for extensions)

    var meetingStartTime: Date?
    private var cancellables = Set<AnyCancellable>()
    private var dataFlowTask: Task<Void, Never>?
    private var isCleaningUp = false

    // MARK: - Callbacks

    var onMeetingStarted: ((MeetingInfo) -> Void)?
    var onMeetingEnded: ((MeetingSummary) -> Void)?
    var onPredictionsUpdated: (([Prediction]) -> Void)?
    var onTranscription: ((String) -> Void)?
    var onError: ((CoordinatorError) -> Void)?

    // MARK: - Initialization

    private init() {
        setupBindings()
        setupNotifications()
        Logger.log("MeetingAssistantCoordinator initialized")
    }

    // MARK: - Setup

    private func setupBindings() {
        // Prediction engine updates
        predictionEngine.onPredictionsUpdated = { [weak self] predictions in
            Task { @MainActor in
                self?.activePredictions = predictions
                self?.onPredictionsUpdated?(predictions)
            }
        }

        predictionEngine.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleError(.predictionError(error))
            }
        }

        // Answer generator updates
        answerGenerator.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleError(.answerError(error))
            }
        }

        // Context updates
        context.onContextUpdated = { [weak self] in
            Task { @MainActor in
                self?.tokenUsage = self?.context.getTokenBudgetStatus()
            }
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.cleanup()
            }
        }
    }

    // MARK: - Meeting Lifecycle

    func startMeeting(title: String? = nil, participants: [String] = []) async throws {
        guard state == .idle else {
            throw CoordinatorError.meetingAlreadyActive
        }

        Logger.log("Starting meeting: \(title ?? "Untitled")")
        state = .starting
        errorMessage = nil

        do {
            // Initialize meeting info
            let meetingInfo = MeetingInfo(
                id: UUID(),
                title: title ?? "Meeting \(formattedDate())",
                participants: participants,
                startTime: Date()
            )
            currentMeeting = meetingInfo
            meetingStartTime = Date()

            // Initialize context
            context.startMeeting(title: meetingInfo.title, participants: participants)

            // Start screen monitoring
            try await startScreenMonitoring()

            // Start audio monitoring
            try await startAudioMonitoring()

            // Start prediction engine
            predictionEngine.updateInterval = settings.predictionUpdateInterval
            predictionEngine.start()

            // Start data flow coordination
            startDataFlowCoordination()

            state = .active
            onMeetingStarted?(meetingInfo)

            Logger.log("Meeting started successfully")

        } catch {
            state = .idle
            currentMeeting = nil
            throw CoordinatorError.startupFailed(error)
        }
    }

    func stopMeeting(generateSummary: Bool = true) async -> MeetingSummary? {
        guard state == .active || state == .paused else {
            Logger.log("Cannot stop meeting - not active")
            return nil
        }

        Logger.log("Stopping meeting")
        state = .stopping

        // Stop all monitors
        await screenMonitor.stop()
        await audioMonitor.stop()
        predictionEngine.stop()

        // Stop data flow
        dataFlowTask?.cancel()
        dataFlowTask = nil

        // End context
        context.endMeeting()

        // Generate summary
        var summary: MeetingSummary?
        if generateSummary, let meeting = currentMeeting {
            summary = await generateMeetingSummary(for: meeting)
        }

        // Cleanup
        let finalSummary = summary ?? MeetingSummary(
            meetingInfo: currentMeeting ?? MeetingInfo(id: UUID(), title: "Unknown", participants: [], startTime: Date()),
            duration: meetingDuration,
            transcriptWordCount: 0,
            topicsDiscussed: [],
            actionItems: [],
            keyDecisions: [],
            aiSummary: nil
        )

        state = .idle
        currentMeeting = nil
        meetingStartTime = nil
        activePredictions = []

        onMeetingEnded?(finalSummary)
        Logger.log("Meeting stopped")

        return finalSummary
    }

    func pauseCapture() {
        guard state == .active else { return }

        Logger.log("Pausing capture")
        state = .paused

        Task {
            await screenMonitor.stop()
            await audioMonitor.stop()
        }

        predictionEngine.stop()
    }

    func resumeCapture() async throws {
        guard state == .paused else { return }

        Logger.log("Resuming capture")

        do {
            try await startScreenMonitoring()
            try await startAudioMonitoring()
            predictionEngine.start()

            state = .active
        } catch {
            throw CoordinatorError.resumeFailed(error)
        }
    }

    // MARK: - Component Startup

    private func startScreenMonitoring() async throws {
        screenMonitor.captureInterval = 2.0
        screenMonitor.enableOCR = true
        screenMonitor.enableAIAnalysis = false

        screenMonitor.onTextExtracted = { [weak self] text in
            Task { @MainActor in
                self?.handleScreenText(text)
            }
        }

        screenMonitor.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleError(.screenCaptureError(error))
            }
        }

        try await screenMonitor.start()
    }

    private func startAudioMonitoring() async throws {
        audioMonitor.chunkDuration = settings.audioChunkDuration
        audioMonitor.silenceThreshold = Float(settings.silenceThreshold)
        audioMonitor.transcriptionMode = .whisperAPI

        audioMonitor.onTranscription = { [weak self] text in
            Task { @MainActor in
                self?.handleTranscription(text)
            }
        }

        audioMonitor.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
            }
        }

        audioMonitor.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleError(.audioCaptureError(error))
            }
        }

        try await audioMonitor.start()
    }

    // MARK: - Data Flow

    private func startDataFlowCoordination() {
        dataFlowTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.state == .active else { break }

                // Periodic context check and token management
                await self.checkContextHealth()

                try? await Task.sleep(nanoseconds: 5_000_000_000)  // Every 5 seconds
            }
        }
    }

    private func handleTranscription(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastTranscription = trimmed

        // Add to context
        context.addTranscription(trimmed)

        // Notify
        onTranscription?(trimmed)

        // Trigger prediction update if significant
        if trimmed.count > 20 {
            predictionEngine.invalidateCache()
        }

        Logger.log("Transcription: \(trimmed.prefix(50))...", level: .debug)
    }

    private func handleScreenText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastScreenText = trimmed

        // Add to context with content type detection
        let contentType = detectContentType(from: trimmed)
        context.updateScreenState(trimmed, contentType: contentType)

        Logger.log("Screen text updated (\(contentType.rawValue))", level: .debug)
    }

    private func detectContentType(from text: String) -> ScreenContentType {
        let lower = text.lowercased()

        if lower.contains("func ") || lower.contains("class ") || lower.contains("import ") {
            return .code
        } else if text.contains("•") || text.split(separator: "\n").count < 10 {
            return .slides
        } else if lower.contains("@") && lower.contains(":") {
            return .chat
        }
        return .document
    }

    private func checkContextHealth() async {
        let status = context.getTokenBudgetStatus()
        tokenUsage = status

        // Auto-compress if over budget
        if status.isOverBudget {
            Logger.log("Token budget exceeded, compressing context")
            do {
                try await context.compressOldContext()
            } catch {
                Logger.log("Context compression failed: \(error)", level: .error)
            }
        }
    }

    // MARK: - Predictions & Answers

    func getActivePredictions() -> [Prediction] {
        return activePredictions
    }

    func refreshPredictions() async {
        await predictionEngine.updateNow()
        activePredictions = predictionEngine.getTopPredictions(count: settings.maxPredictionsToShow)
    }

    func answerQuestion(
        _ question: String,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (AnswerResult) -> Void
    ) async {
        await answerGenerator.generateAnswer(
            for: question,
            onToken: onToken,
            onComplete: onComplete
        )
    }

    func getQuickAnswer(for question: String) async throws -> String {
        return try await answerGenerator.quickAnswer(for: question)
    }

    // MARK: - Meeting Summary

    private func generateMeetingSummary(for meeting: MeetingInfo) async -> MeetingSummary {
        let fullContext = context.getFullContext()

        // Get AI summary
        var aiSummary: String?
        do {
            aiSummary = try await context.generateRunningSummary()
        } catch {
            Logger.log("Failed to generate AI summary: \(error)", level: .error)
        }

        // Extract action items
        var actionItems: [String] = []
        do {
            let items = try await context.extractActionItemsWithAI()
            actionItems = items
        } catch {
            Logger.log("Failed to extract action items: \(error)", level: .error)
        }

        let wordCount = fullContext.transcriptions.map { $0.text.split(separator: " ").count }.reduce(0, +)

        return MeetingSummary(
            meetingInfo: meeting,
            duration: meetingDuration,
            transcriptWordCount: wordCount,
            topicsDiscussed: fullContext.topics,
            actionItems: actionItems,
            keyDecisions: fullContext.keyDecisions,
            aiSummary: aiSummary
        )
    }

    // MARK: - Export & Notes

    private let exporter = MeetingExporter.shared
    @Published private(set) var lastExportResult: MeetingExporter.ExportResult?

    func generateMeetingNotes() async throws -> MeetingExporter.ExportResult {
        guard let meeting = currentMeeting else {
            throw CoordinatorError.meetingNotActive
        }

        let fullContext = context.getFullContext()
        let result = try await exporter.generateExport(
            from: fullContext,
            meetingInfo: meeting,
            predictions: activePredictions
        )

        lastExportResult = result
        return result
    }

    func exportToClipboard(format: ExportFormat = .markdown) async throws {
        let result = try await generateMeetingNotes()

        switch format {
        case .markdown:
            exporter.copyToClipboard(result.markdownContent, format: .markdown)
        case .plainText:
            exporter.copyToClipboard(result.plainTextContent, format: .plainText)
        case .html:
            exporter.copyToClipboard(result.emailDraft.htmlBody, format: .html)
        }

        Logger.log("Meeting notes copied to clipboard (\(format))")
    }

    func exportActionItems() {
        let fullContext = context.getFullContext()
        let items = fullContext.actionItems.map { item in
            MeetingExporter.ExportedActionItem(
                description: item.description,
                owner: item.assignee,
                dueDate: item.dueDate,
                priority: .medium
            )
        }
        exporter.copyActionItems(items)
        Logger.log("Action items copied to clipboard")
    }

    func openFollowUpEmail() async throws {
        let result = try await generateMeetingNotes()
        exporter.openInMail(result.emailDraft)
    }

    func saveMeetingNotes() async throws {
        let result = try await generateMeetingNotes()
        exporter.saveMarkdownNotes(result.meetingNotes) { saveResult in
            switch saveResult {
            case .success(let url):
                Logger.log("Meeting notes saved to \(url.path)")
            case .failure(let error):
                Logger.log("Failed to save meeting notes: \(error)", level: .error)
            }
        }
    }

    // MARK: - Error Handling

    private func handleError(_ error: CoordinatorError) {
        Logger.log("Error: \(error.localizedDescription)", level: .error)
        errorMessage = error.localizedDescription
        onError?(error)

        // Auto-recover for non-fatal errors
        switch error {
        case .screenCaptureError, .audioCaptureError:
            // Try to continue with available data
            break
        case .predictionError, .answerError:
            // These are recoverable, just log
            break
        default:
            break
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Cleanup

    func cleanup() async {
        guard !isCleaningUp else { return }
        isCleaningUp = true

        Logger.log("Cleaning up coordinator")

        if state == .active || state == .paused {
            _ = await stopMeeting(generateSummary: false)
        }

        // Cancel all tasks
        dataFlowTask?.cancel()
        cancellables.removeAll()

        // Clear context
        context.clear()

        // Clear caches
        predictionEngine.clearPredictions()
        answerGenerator.clearHistory()
        AnswerCache.shared.clear()

        isCleaningUp = false
        Logger.log("Cleanup complete")
    }

    // MARK: - Helpers

    var meetingDuration: TimeInterval {
        guard let start = meetingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }

    // MARK: - Export

    func exportTranscript() -> String {
        let fullContext = context.getFullContext()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        var output = "Meeting Transcript\n"
        output += "==================\n"

        if let meeting = currentMeeting {
            output += "Title: \(meeting.title)\n"
            output += "Date: \(formattedDate())\n"
            if !meeting.participants.isEmpty {
                output += "Participants: \(meeting.participants.joined(separator: ", "))\n"
            }
        }

        output += "\n--- Transcript ---\n\n"

        for entry in fullContext.transcriptions {
            let time = formatter.string(from: entry.timestamp)
            let speaker = entry.speaker ?? "Speaker"
            output += "[\(time)] \(speaker): \(entry.text)\n"
        }

        if !fullContext.actionItems.isEmpty {
            output += "\n--- Action Items ---\n\n"
            for item in fullContext.actionItems {
                output += "• \(item.description)"
                if let assignee = item.assignee {
                    output += " (@\(assignee))"
                }
                output += "\n"
            }
        }

        return output
    }

    func exportToJSON() throws -> Data {
        let fullContext = context.getFullContext()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let export = MeetingExport(
            meeting: currentMeeting,
            context: fullContext,
            predictions: activePredictions,
            exportDate: Date()
        )

        return try encoder.encode(export)
    }
}

// MARK: - Data Types

enum MeetingState: String {
    case idle = "Idle"
    case starting = "Starting"
    case active = "Active"
    case paused = "Paused"
    case stopping = "Stopping"

    var isCapturing: Bool {
        self == .active
    }
}

struct MeetingInfo: Codable, Identifiable {
    let id: UUID
    let title: String
    let participants: [String]
    let startTime: Date
    var platform: String?
}

struct MeetingSummary {
    let meetingInfo: MeetingInfo
    let duration: TimeInterval
    let transcriptWordCount: Int
    let topicsDiscussed: [String]
    let actionItems: [String]
    let keyDecisions: [String]
    let aiSummary: String?

    var formattedDuration: String {
        let minutes = Int(duration / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }
}

struct MeetingExport: Codable {
    let meeting: MeetingInfo?
    let context: FullMeetingContext
    let predictions: [Prediction]
    let exportDate: Date
}

// MARK: - Errors

enum CoordinatorError: Error, LocalizedError {
    case meetingAlreadyActive
    case meetingNotActive
    case startupFailed(Error)
    case resumeFailed(Error)
    case screenCaptureError(Error)
    case audioCaptureError(Error)
    case predictionError(Error)
    case answerError(Error)
    case exportFailed(Error)

    var errorDescription: String? {
        switch self {
        case .meetingAlreadyActive:
            return "A meeting is already in progress"
        case .meetingNotActive:
            return "No active meeting"
        case .startupFailed(let error):
            return "Failed to start meeting: \(error.localizedDescription)"
        case .resumeFailed(let error):
            return "Failed to resume: \(error.localizedDescription)"
        case .screenCaptureError(let error):
            return "Screen capture error: \(error.localizedDescription)"
        case .audioCaptureError(let error):
            return "Audio capture error: \(error.localizedDescription)"
        case .predictionError(let error):
            return "Prediction error: \(error.localizedDescription)"
        case .answerError(let error):
            return "Answer error: \(error.localizedDescription)"
        case .exportFailed(let error):
            return "Export failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Logger

struct Logger {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }

    static var isEnabled: Bool {
        SettingsManager.shared.debugLogging
    }

    static func log(_ message: String, level: Level = .info, file: String = #file, function: String = #function, line: Int = #line) {
        guard isEnabled || level == .error else { return }

        let filename = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())

        print("[\(timestamp)] [\(level.rawValue)] [\(filename):\(line)] \(message)")
    }
}
