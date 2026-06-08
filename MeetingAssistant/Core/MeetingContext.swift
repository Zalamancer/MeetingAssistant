import Foundation

// MARK: - Meeting Context Manager

final class MeetingContext: @unchecked Sendable {
    static let shared = MeetingContext()

    // Configuration
    private let maxTranscriptionMessages = 15
    private let maxScreenStates = 5
    private let targetTokenCount = 2000
    private let tokensPerChar: Double = 0.25  // Rough estimate: ~4 chars per token

    // State
    private var transcriptions: [TranscriptionEntry] = []
    private var screenStates: [ScreenState] = []
    private var metadata: MeetingMetadata
    private var topics: [String] = []
    private var actionItems: [ActionItem] = []
    private var keyDecisions: [String] = []

    // Thread safety
    private let lock = NSLock()

    // Callbacks
    var onContextUpdated: (() -> Void)?

    private init() {
        metadata = MeetingMetadata()
    }

    // MARK: - Transcription Management

    func addTranscription(_ text: String, speaker: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let entry = TranscriptionEntry(
            id: UUID(),
            text: trimmedText,
            speaker: speaker,
            timestamp: Date()
        )

        transcriptions.append(entry)

        // Extract potential action items and topics inline
        extractInsights(from: trimmedText)

        // Trim if needed
        trimTranscriptions()

        onContextUpdated?()
    }

    func addTranscriptions(_ texts: [String]) {
        for text in texts {
            addTranscription(text)
        }
    }

    private func trimTranscriptions() {
        // Keep only recent messages
        if transcriptions.count > maxTranscriptionMessages {
            let overflow = transcriptions.count - maxTranscriptionMessages
            transcriptions.removeFirst(overflow)
        }

        // Also check token budget
        while estimateTokens() > targetTokenCount && transcriptions.count > 3 {
            transcriptions.removeFirst()
        }
    }

    // MARK: - Screen State Management

    func updateScreenState(_ text: String, contentType: ScreenContentType = .unknown) {
        lock.lock()
        defer { lock.unlock() }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Check if significantly different from last state
        if let lastState = screenStates.last {
            let similarity = calculateSimilarity(trimmedText, lastState.text)
            if similarity > 0.8 { return }  // Skip if too similar
        }

        let state = ScreenState(
            id: UUID(),
            text: trimmedText,
            contentType: contentType,
            timestamp: Date()
        )

        screenStates.append(state)

        // Keep only recent screen states
        if screenStates.count > maxScreenStates {
            screenStates.removeFirst()
        }

        onContextUpdated?()
    }

    // MARK: - Metadata Management

    func startMeeting(title: String? = nil, participants: [String] = []) {
        lock.lock()
        defer { lock.unlock() }

        metadata = MeetingMetadata(
            startTime: Date(),
            title: title,
            participants: participants
        )

        // Clear previous context
        transcriptions.removeAll()
        screenStates.removeAll()
        topics.removeAll()
        actionItems.removeAll()
        keyDecisions.removeAll()

        onContextUpdated?()
    }

    func endMeeting() {
        lock.lock()
        defer { lock.unlock() }

        metadata.endTime = Date()
        onContextUpdated?()
    }

    func addParticipant(_ name: String) {
        lock.lock()
        defer { lock.unlock() }

        if !metadata.participants.contains(name) {
            metadata.participants.append(name)
        }
    }

    func setMeetingTitle(_ title: String) {
        lock.lock()
        defer { lock.unlock() }

        metadata.title = title
    }

    // MARK: - Topics & Action Items

    func addTopic(_ topic: String) {
        lock.lock()
        defer { lock.unlock() }

        if !topics.contains(topic) {
            topics.append(topic)
        }
    }

    func addActionItem(_ item: String, assignee: String? = nil, dueDate: Date? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let actionItem = ActionItem(
            description: item,
            assignee: assignee,
            dueDate: dueDate,
            createdAt: Date()
        )
        actionItems.append(actionItem)
    }

    func addKeyDecision(_ decision: String) {
        lock.lock()
        defer { lock.unlock() }

        keyDecisions.append(decision)
    }

    // MARK: - Context Summary for Claude

    func getContextSummary() -> String {
        lock.lock()
        defer { lock.unlock() }

        var parts: [String] = []

        // Meeting metadata
        parts.append(buildMetadataSection())

        // Topics discussed
        if !topics.isEmpty {
            parts.append("TOPICS: \(topics.joined(separator: ", "))")
        }

        // Current screen content
        if let currentScreen = screenStates.last {
            parts.append("CURRENT SCREEN (\(currentScreen.contentType.rawValue)):\n\(currentScreen.text.prefix(500))")
        }

        // Recent transcription
        let recentTranscript = buildTranscriptSection()
        if !recentTranscript.isEmpty {
            parts.append("RECENT DISCUSSION:\n\(recentTranscript)")
        }

        // Action items so far
        if !actionItems.isEmpty {
            let items = actionItems.map { "- \($0.description)" + ($0.assignee != nil ? " (@\($0.assignee!))" : "") }
            parts.append("ACTION ITEMS IDENTIFIED:\n\(items.joined(separator: "\n"))")
        }

        return parts.joined(separator: "\n\n")
    }

    func getContextForPrediction() -> String {
        lock.lock()
        defer { lock.unlock() }

        // Lighter context for real-time predictions
        var parts: [String] = []

        // Last few transcriptions only
        let recent = transcriptions.suffix(5)
        if !recent.isEmpty {
            let text = recent.map { $0.text }.joined(separator: " ")
            parts.append("Recent: \(text)")
        }

        // Current screen (abbreviated)
        if let screen = screenStates.last {
            parts.append("Screen: \(screen.text.prefix(200))")
        }

        return parts.joined(separator: "\n")
    }

    func getFullContext() -> FullMeetingContext {
        lock.lock()
        defer { lock.unlock() }

        return FullMeetingContext(
            metadata: metadata,
            transcriptions: transcriptions,
            screenStates: screenStates,
            topics: topics,
            actionItems: actionItems,
            keyDecisions: keyDecisions,
            estimatedTokens: estimateTokensUnlocked()
        )
    }

    // MARK: - Claude Conversation History

    func getClaudeMessages() -> [Message] {
        lock.lock()
        defer { lock.unlock() }

        // Build a condensed conversation for Claude
        var messages: [Message] = []

        // System context as first user message
        let contextSummary = "Meeting context:\n" + buildMetadataSectionUnlocked()
        messages.append(Message(role: .user, content: contextSummary))
        messages.append(Message(role: .assistant, content: "I understand. I'm tracking this meeting and ready to help."))

        // Recent transcriptions as user messages
        for entry in transcriptions.suffix(10) {
            let speaker = entry.speaker ?? "Participant"
            messages.append(Message(role: .user, content: "[\(speaker)]: \(entry.text)"))
        }

        return messages
    }

    // MARK: - Token Estimation

    func estimateTokens() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return estimateTokensUnlocked()
    }

    private func estimateTokensUnlocked() -> Int {
        var totalChars = 0

        // Transcriptions
        for entry in transcriptions {
            totalChars += entry.text.count
            totalChars += (entry.speaker?.count ?? 0) + 10  // Overhead
        }

        // Screen states
        for state in screenStates {
            totalChars += min(state.text.count, 500)  // Cap screen text
        }

        // Metadata
        totalChars += (metadata.title?.count ?? 0) + 50
        totalChars += metadata.participants.joined().count

        // Topics and action items
        totalChars += topics.joined().count
        totalChars += actionItems.map { $0.description }.joined().count

        return Int(Double(totalChars) * tokensPerChar)
    }

    func getTokenBudgetStatus() -> TokenBudgetStatus {
        let current = estimateTokens()
        return TokenBudgetStatus(
            currentTokens: current,
            targetTokens: targetTokenCount,
            utilizationPercent: Double(current) / Double(targetTokenCount) * 100
        )
    }

    // MARK: - Clear / Reset

    func clearOldMessages() {
        lock.lock()
        defer { lock.unlock() }

        // Keep only last 5 transcriptions
        if transcriptions.count > 5 {
            transcriptions = Array(transcriptions.suffix(5))
        }

        // Keep only last 2 screen states
        if screenStates.count > 2 {
            screenStates = Array(screenStates.suffix(2))
        }

        onContextUpdated?()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        transcriptions.removeAll()
        screenStates.removeAll()
        topics.removeAll()
        actionItems.removeAll()
        keyDecisions.removeAll()
        metadata = MeetingMetadata()

        onContextUpdated?()
    }

    // MARK: - Private Helpers

    private func buildMetadataSection() -> String {
        buildMetadataSectionUnlocked()
    }

    private func buildMetadataSectionUnlocked() -> String {
        var parts: [String] = []

        if let title = metadata.title {
            parts.append("Meeting: \(title)")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        if let start = metadata.startTime {
            let duration = metadata.endTime ?? Date()
            let mins = Int(duration.timeIntervalSince(start) / 60)
            parts.append("Started: \(formatter.string(from: start)) (\(mins) min)")
        }

        if !metadata.participants.isEmpty {
            parts.append("Participants: \(metadata.participants.joined(separator: ", "))")
        }

        return parts.isEmpty ? "Meeting in progress" : parts.joined(separator: " | ")
    }

    private func buildTranscriptSection() -> String {
        let recent = transcriptions.suffix(10)
        return recent.map { entry in
            let speaker = entry.speaker ?? "Speaker"
            return "[\(speaker)]: \(entry.text)"
        }.joined(separator: "\n")
    }

    private func extractInsights(from text: String) {
        let lowercased = text.lowercased()

        // Simple action item detection
        let actionPhrases = ["i will", "i'll", "let me", "action item", "todo", "need to", "should", "must", "will do"]
        for phrase in actionPhrases {
            if lowercased.contains(phrase) {
                // Could use Claude to extract proper action items
                break
            }
        }

        // Simple topic detection
        let topicIndicators = ["let's talk about", "moving on to", "next topic", "regarding", "about the"]
        for indicator in topicIndicators {
            if lowercased.contains(indicator) {
                // Could extract topic
                break
            }
        }
    }

    private func calculateSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.lowercased().split(separator: " "))
        let words2 = Set(text2.lowercased().split(separator: " "))

        guard !words1.isEmpty || !words2.isEmpty else { return 1.0 }

        let intersection = words1.intersection(words2).count
        let union = words1.union(words2).count

        return Double(intersection) / Double(union)
    }
}

// MARK: - Data Types

struct TranscriptionEntry: Identifiable, Codable {
    let id: UUID
    let text: String
    let speaker: String?
    let timestamp: Date
}

struct ScreenState: Identifiable, Codable {
    let id: UUID
    let text: String
    let contentType: ScreenContentType
    let timestamp: Date
}

enum ScreenContentType: String, Codable {
    case slides = "Slides"
    case document = "Document"
    case code = "Code"
    case chat = "Chat"
    case browser = "Browser"
    case unknown = "Screen"
}

struct MeetingMetadata: Codable {
    var startTime: Date?
    var endTime: Date?
    var title: String?
    var participants: [String] = []
    var platform: String?  // Zoom, Teams, etc.
}

struct ActionItem: Codable {
    let description: String
    let assignee: String?
    let dueDate: Date?
    let createdAt: Date
}

struct FullMeetingContext: Codable {
    let metadata: MeetingMetadata
    let transcriptions: [TranscriptionEntry]
    let screenStates: [ScreenState]
    let topics: [String]
    let actionItems: [ActionItem]
    let keyDecisions: [String]
    let estimatedTokens: Int
}

struct TokenBudgetStatus {
    let currentTokens: Int
    let targetTokens: Int
    let utilizationPercent: Double

    var isOverBudget: Bool {
        currentTokens > targetTokens
    }

    var description: String {
        "\(currentTokens)/\(targetTokens) tokens (\(Int(utilizationPercent))%)"
    }
}
