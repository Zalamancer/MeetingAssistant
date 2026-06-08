import Foundation

// MARK: - Live Answer Generator

final class LiveAnswerGenerator: @unchecked Sendable {
    static let shared = LiveAnswerGenerator()

    // Configuration
    var timeout: TimeInterval = 5.0
    var maxAnswerLength = 150  // Words
    var includeSourceReferences = true

    // State
    private(set) var isGenerating = false
    private(set) var currentQuestion: String?
    private(set) var currentAnswer: String = ""
    private(set) var lastAnswer: AnswerResult?

    // Conversation for follow-ups
    private var conversationHistory: [(question: String, answer: String)] = []
    private let maxHistoryItems = 5

    // Dependencies
    private let claude = ClaudeAPIClient.shared
    private let context = MeetingContext.shared

    // Callbacks
    var onTokenReceived: ((String) -> Void)?
    var onAnswerComplete: ((AnswerResult) -> Void)?
    var onError: ((LiveAnswerError) -> Void)?

    private init() {}

    // MARK: - Generate Answer (Streaming)

    func generateAnswer(
        for question: String,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (AnswerResult) -> Void
    ) async {
        guard !isGenerating else {
            onComplete(AnswerResult(
                question: question,
                answer: "Already generating an answer...",
                confidence: .low,
                sources: [],
                duration: 0
            ))
            return
        }

        isGenerating = true
        currentQuestion = question
        currentAnswer = ""

        let startTime = Date()

        do {
            let prompt = buildPrompt(for: question)

            // Stream with timeout
            let answer = try await withTimeout(seconds: timeout) {
                try await self.streamAnswer(prompt: prompt, onToken: onToken)
            }

            let duration = Date().timeIntervalSince(startTime)
            let result = AnswerResult(
                question: question,
                answer: answer,
                confidence: assessConfidence(answer),
                sources: extractSources(from: answer),
                duration: duration
            )

            // Store for follow-ups
            conversationHistory.append((question: question, answer: answer))
            if conversationHistory.count > maxHistoryItems {
                conversationHistory.removeFirst()
            }

            lastAnswer = result
            currentAnswer = answer
            isGenerating = false

            onComplete(result)
            onAnswerComplete?(result)

        } catch let error as LiveAnswerError {
            isGenerating = false
            onError?(error)
            onComplete(AnswerResult(
                question: question,
                answer: "Unable to generate answer: \(error.localizedDescription)",
                confidence: .none,
                sources: [],
                duration: Date().timeIntervalSince(startTime)
            ))
        } catch {
            isGenerating = false
            let liveError = LiveAnswerError.generationFailed(error)
            onError?(liveError)
            onComplete(AnswerResult(
                question: question,
                answer: "Error: \(error.localizedDescription)",
                confidence: .none,
                sources: [],
                duration: Date().timeIntervalSince(startTime)
            ))
        }
    }

    // MARK: - Streaming Implementation

    private func streamAnswer(prompt: String, onToken: @escaping (String) -> Void) async throws -> String {
        var fullResponse = ""

        for try await token in claude.streamTokens(prompt, includeHistory: false) {
            fullResponse += token
            await MainActor.run {
                onToken(token)
            }

            // Check if we've reached a reasonable stopping point
            if fullResponse.count > maxAnswerLength * 6 {  // ~6 chars per word
                break
            }
        }

        return fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Follow-up Questions

    func generateFollowUp(
        _ followUpQuestion: String,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (AnswerResult) -> Void
    ) async {
        guard let lastQ = conversationHistory.last else {
            await generateAnswer(for: followUpQuestion, onToken: onToken, onComplete: onComplete)
            return
        }

        isGenerating = true
        currentQuestion = followUpQuestion
        currentAnswer = ""

        let startTime = Date()

        let prompt = buildFollowUpPrompt(
            originalQuestion: lastQ.question,
            originalAnswer: lastQ.answer,
            followUp: followUpQuestion
        )

        do {
            let answer = try await withTimeout(seconds: timeout) {
                try await self.streamAnswer(prompt: prompt, onToken: onToken)
            }

            let duration = Date().timeIntervalSince(startTime)
            let result = AnswerResult(
                question: followUpQuestion,
                answer: answer,
                confidence: assessConfidence(answer),
                sources: extractSources(from: answer),
                duration: duration,
                isFollowUp: true
            )

            conversationHistory.append((question: followUpQuestion, answer: answer))
            if conversationHistory.count > maxHistoryItems {
                conversationHistory.removeFirst()
            }

            lastAnswer = result
            currentAnswer = answer
            isGenerating = false

            onComplete(result)

        } catch {
            isGenerating = false
            onComplete(AnswerResult(
                question: followUpQuestion,
                answer: "Unable to answer follow-up: \(error.localizedDescription)",
                confidence: .none,
                sources: [],
                duration: Date().timeIntervalSince(startTime),
                isFollowUp: true
            ))
        }
    }

    // MARK: - Quick Answer (Non-streaming)

    func quickAnswer(for question: String) async throws -> String {
        let prompt = buildPrompt(for: question)

        return try await withTimeout(seconds: timeout) {
            try await self.claude.predict(prompt)
        }
    }

    // MARK: - Prompt Building

    private func buildPrompt(for question: String) -> String {
        let contextSummary = context.getContextSummary()
        let screenText = context.getFullContext().screenStates.last?.text ?? ""

        return """
        You are an expert meeting assistant. Answer the question based ONLY on what's been discussed in this meeting. Be concise (1-2 sentences). If you don't have enough information from the meeting, say "Not discussed yet."

        Meeting transcript:
        \(contextSummary.prefix(2500))

        Screen content:
        \(screenText.prefix(800))

        Question: \(question)

        Answer directly and concisely:
        """
    }

    private func buildFollowUpPrompt(originalQuestion: String, originalAnswer: String, followUp: String) -> String {
        let contextSummary = context.getContextForPrediction()

        return """
        You are an expert meeting assistant continuing a conversation.

        Previous exchange:
        Q: \(originalQuestion)
        A: \(originalAnswer)

        Meeting context:
        \(contextSummary.prefix(1500))

        Follow-up question: \(followUp)

        Answer the follow-up concisely (1-2 sentences):
        """
    }

    // MARK: - Confidence Assessment

    private func assessConfidence(_ answer: String) -> AnswerConfidence {
        let lower = answer.lowercased()

        // Low confidence indicators
        if lower.contains("not discussed") ||
           lower.contains("no information") ||
           lower.contains("unclear") ||
           lower.contains("don't have") ||
           lower.contains("not mentioned") {
            return .low
        }

        // Medium confidence indicators
        if lower.contains("might") ||
           lower.contains("possibly") ||
           lower.contains("seems") ||
           lower.contains("appears") {
            return .medium
        }

        // High confidence if definitive
        return .high
    }

    private func extractSources(from answer: String) -> [String] {
        // Simple source extraction - could be enhanced
        var sources: [String] = []

        let participants = context.getFullContext().metadata.participants
        for participant in participants {
            if answer.lowercased().contains(participant.lowercased()) {
                sources.append(participant)
            }
        }

        return sources
    }

    // MARK: - Timeout Helper

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LiveAnswerError.timeout
            }

            guard let result = try await group.next() else {
                throw LiveAnswerError.timeout
            }

            group.cancelAll()
            return result
        }
    }

    // MARK: - State Management

    func cancel() {
        isGenerating = false
        currentQuestion = nil
    }

    func clearHistory() {
        conversationHistory.removeAll()
        lastAnswer = nil
    }
}

// MARK: - Data Types

struct AnswerResult {
    let question: String
    let answer: String
    let confidence: AnswerConfidence
    let sources: [String]
    let duration: TimeInterval
    var isFollowUp: Bool = false

    var formattedDuration: String {
        String(format: "%.1fs", duration)
    }
}

enum AnswerConfidence: String {
    case high = "High"
    case medium = "Medium"
    case low = "Low"
    case none = "None"

    var color: String {
        switch self {
        case .high: return "green"
        case .medium: return "yellow"
        case .low: return "orange"
        case .none: return "gray"
        }
    }

    var icon: String {
        switch self {
        case .high: return "checkmark.circle.fill"
        case .medium: return "checkmark.circle"
        case .low: return "questionmark.circle"
        case .none: return "xmark.circle"
        }
    }
}

// MARK: - Errors

enum LiveAnswerError: Error, LocalizedError {
    case timeout
    case alreadyGenerating
    case noContext
    case generationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Answer generation timed out"
        case .alreadyGenerating:
            return "Already generating an answer"
        case .noContext:
            return "No meeting context available"
        case .generationFailed(let error):
            return "Generation failed: \(error.localizedDescription)"
        }
    }
}
