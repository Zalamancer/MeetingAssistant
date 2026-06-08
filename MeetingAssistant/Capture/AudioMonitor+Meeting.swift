import Foundation
import AppKit

// MARK: - Meeting-Specific Extensions

@available(macOS 13.0, *)
extension AudioMonitor {
    /// Start with meeting-optimized settings
    func startMeetingTranscription(
        onTranscript: @escaping (String) -> Void,
        onLevel: ((Float) -> Void)? = nil
    ) async throws {
        // Optimize for meeting transcription
        chunkDuration = 5.0          // 5 second chunks
        silenceThreshold = 0.005     // More sensitive
        transcriptionMode = .whisperAPI

        onTranscription = onTranscript
        onAudioLevel = onLevel

        try await start()
    }

    /// Get full transcript from buffer
    func getFullTranscript(from buffer: TranscriptionBuffer) -> String {
        buffer.getFullTranscript()
    }
}

// MARK: - Transcription Buffer

final class TranscriptionBuffer {
    private var entries: [TranscriptEntry] = []
    private let lock = NSLock()
    private let maxEntries = 500

    struct TranscriptEntry {
        let text: String
        let timestamp: Date
        let confidence: Float?
        let speaker: String?
    }

    func add(_ text: String, speaker: String? = nil, confidence: Float? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let entry = TranscriptEntry(
            text: text,
            timestamp: Date(),
            confidence: confidence,
            speaker: speaker
        )

        entries.append(entry)

        // Trim if too large
        if entries.count > maxEntries {
            entries.removeFirst(50)
        }
    }

    func getRecent(count: Int = 10) -> [TranscriptEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(count))
    }

    func getAll() -> [TranscriptEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func getFullTranscript() -> String {
        lock.lock()
        defer { lock.unlock() }
        return entries.map { $0.text }.joined(separator: " ")
    }

    func getTranscriptSince(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return entries
            .filter { $0.timestamp >= date }
            .map { $0.text }
            .joined(separator: " ")
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Export as formatted transcript with timestamps
    func exportFormatted() -> String {
        lock.lock()
        defer { lock.unlock() }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        return entries.map { entry in
            let time = formatter.string(from: entry.timestamp)
            let speaker = entry.speaker ?? "Speaker"
            return "[\(time)] \(speaker): \(entry.text)"
        }.joined(separator: "\n")
    }
}

// MARK: - Combined Capture Manager

@available(macOS 13.0, *)
final class MeetingCaptureManager {
    static let shared = MeetingCaptureManager()

    let screenMonitor = ScreenMonitor.shared
    let audioMonitor = AudioMonitor.shared
    let context = MeetingContext.shared

    let screenBuffer = ScreenContentBuffer()
    let transcriptBuffer = TranscriptionBuffer()

    private(set) var isCapturing = false
    private var meetingStartTime: Date?

    var onStatusUpdate: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onScreenText: ((String) -> Void)?
    var onContextUpdate: ((MeetingContext) -> Void)?

    private init() {}

    func startCapture(title: String? = nil, participants: [String] = []) async throws {
        guard !isCapturing else { return }

        meetingStartTime = Date()
        isCapturing = true

        // Initialize context
        context.startMeeting(title: title, participants: participants)

        // Start screen capture
        try await screenMonitor.startMeetingCapture(
            onText: { [weak self] text in
                self?.screenBuffer.add(text)
                self?.context.updateScreenState(text)
                self?.onScreenText?(text)
            }
        )

        // Start audio capture
        try await audioMonitor.startMeetingTranscription(
            onTranscript: { [weak self] text in
                self?.transcriptBuffer.add(text)
                self?.context.addTranscription(text)
                self?.onTranscript?(text)
                self?.onContextUpdate?(self!.context)
            },
            onLevel: { level in
                // Could update UI with audio level indicator
            }
        )

        onStatusUpdate?("Capturing meeting...")
    }

    func stopCapture() async {
        guard isCapturing else { return }

        await screenMonitor.stop()
        await audioMonitor.stop()

        context.endMeeting()
        isCapturing = false
        onStatusUpdate?("Capture stopped")
    }

    // MARK: - Context Access

    func getContextSummary() -> String {
        context.getContextSummary()
    }

    func getTokenStatus() -> TokenBudgetStatus {
        context.getTokenBudgetStatus()
    }

    func getMeetingSummary() async throws -> String {
        let transcript = transcriptBuffer.getFullTranscript()
        let screenContent = screenBuffer.getRecent(count: 10).map { $0.text }.joined(separator: "\n")

        guard !transcript.isEmpty || !screenContent.isEmpty else {
            return "No meeting content captured."
        }

        let prompt = """
        Summarize this meeting based on the transcript and screen content.
        Include: key topics, decisions, and action items.

        TRANSCRIPT:
        \(transcript.prefix(4000))

        SCREEN CONTENT (slides/documents shown):
        \(screenContent.prefix(2000))
        """

        return try await ClaudeAPIClient.shared.sendMessage(prompt, includeHistory: false)
    }

    func getActionItems() async throws -> String {
        let transcript = transcriptBuffer.getFullTranscript()

        guard !transcript.isEmpty else {
            return "No transcript available."
        }

        return try await ClaudeAPIClient.shared.extractActionItems(transcript)
    }

    func exportTranscript() -> String {
        transcriptBuffer.exportFormatted()
    }

    func clearBuffers() {
        screenBuffer.clear()
        transcriptBuffer.clear()
        meetingStartTime = nil
    }
}
