import Foundation

// MARK: - Advanced Features

extension LiveAnswerGenerator {
    /// Detect if text contains a question and auto-answer
    func detectAndAnswer(
        transcript: String,
        onQuestionDetected: @escaping (String) -> Void,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (AnswerResult) -> Void
    ) async {
        // Check if transcript contains a question
        guard let question = extractQuestion(from: transcript) else {
            return
        }

        onQuestionDetected(question)
        await generateAnswer(for: question, onToken: onToken, onComplete: onComplete)
    }

    private func extractQuestion(from text: String) -> String? {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))

        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)

            // Check for question indicators
            let lowerCase = trimmed.lowercased()
            let questionStarters = ["what", "when", "where", "who", "why", "how", "can", "could", "would", "should", "is", "are", "do", "does", "did", "will"]

            for starter in questionStarters {
                if lowerCase.hasPrefix(starter + " ") {
                    return trimmed + "?"
                }
            }

            // Check for question marks in original
            if text.contains(trimmed + "?") {
                return trimmed + "?"
            }
        }

        return nil
    }

    /// Answer multiple questions at once
    func batchAnswer(
        questions: [String],
        onProgress: @escaping (Int, Int, AnswerResult) -> Void
    ) async -> [AnswerResult] {
        var results: [AnswerResult] = []

        for (index, question) in questions.enumerated() {
            var currentAnswer = ""

            await generateAnswer(
                for: question,
                onToken: { token in currentAnswer += token },
                onComplete: { result in
                    results.append(result)
                    onProgress(index + 1, questions.count, result)
                }
            )

            // Small delay between questions to avoid rate limiting
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return results
    }

    /// Generate answer with specific focus area
    func generateFocusedAnswer(
        for question: String,
        focus: AnswerFocus,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (AnswerResult) -> Void
    ) async {
        let enhancedQuestion = enhanceQuestion(question, with: focus)
        await generateAnswer(for: enhancedQuestion, onToken: onToken, onComplete: onComplete)
    }

    private func enhanceQuestion(_ question: String, with focus: AnswerFocus) -> String {
        switch focus {
        case .technical:
            return "\(question) (Focus on technical details)"
        case .timeline:
            return "\(question) (Focus on dates and timelines)"
        case .ownership:
            return "\(question) (Focus on who is responsible)"
        case .decision:
            return "\(question) (Focus on what was decided)"
        case .actionItem:
            return "\(question) (Focus on action items)"
        case .summary:
            return "\(question) (Provide a brief summary)"
        }
    }
}

enum AnswerFocus: String, CaseIterable {
    case technical = "Technical"
    case timeline = "Timeline"
    case ownership = "Ownership"
    case decision = "Decision"
    case actionItem = "Action Item"
    case summary = "Summary"
}

// MARK: - Smart Answer Caching

final class AnswerCache {
    static let shared = AnswerCache()

    private var cache: [String: CachedAnswer] = [:]
    private let maxCacheSize = 50
    private let cacheExpiry: TimeInterval = 300  // 5 minutes

    private init() {}

    struct CachedAnswer {
        let result: AnswerResult
        let contextHash: Int
        let timestamp: Date
    }

    func get(for question: String, contextHash: Int) -> AnswerResult? {
        let key = normalizeQuestion(question)

        guard let cached = cache[key],
              cached.contextHash == contextHash,
              Date().timeIntervalSince(cached.timestamp) < cacheExpiry else {
            return nil
        }

        return cached.result
    }

    func store(_ result: AnswerResult, contextHash: Int) {
        let key = normalizeQuestion(result.question)

        cache[key] = CachedAnswer(
            result: result,
            contextHash: contextHash,
            timestamp: Date()
        )

        // Trim cache if too large
        if cache.count > maxCacheSize {
            trimOldestEntries()
        }
    }

    private func normalizeQuestion(_ question: String) -> String {
        question.lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespaces)
    }

    private func trimOldestEntries() {
        let sorted = cache.sorted { $0.value.timestamp < $1.value.timestamp }
        let toRemove = sorted.prefix(10)
        for (key, _) in toRemove {
            cache.removeValue(forKey: key)
        }
    }

    func clear() {
        cache.removeAll()
    }

    func invalidate(for question: String) {
        let key = normalizeQuestion(question)
        cache.removeValue(forKey: key)
    }
}

// MARK: - Answer Enhancement

extension LiveAnswerGenerator {
    /// Enhance an answer with additional context
    func enhanceAnswer(_ answer: AnswerResult) async throws -> AnswerResult {
        let prompt = """
        Enhance this meeting answer with more context if available.
        Keep it concise (2-3 sentences max).

        Original question: \(answer.question)
        Original answer: \(answer.answer)

        Meeting context:
        \(MeetingContext.shared.getContextForPrediction())

        Enhanced answer:
        """

        let enhanced = try await ClaudeAPIClient.shared.predict(prompt)

        return AnswerResult(
            question: answer.question,
            answer: enhanced,
            confidence: answer.confidence,
            sources: answer.sources,
            duration: answer.duration,
            isFollowUp: answer.isFollowUp
        )
    }

    /// Rephrase answer in different tone
    func rephraseAnswer(_ answer: AnswerResult, tone: AnswerTone) async throws -> String {
        let prompt = """
        Rephrase this answer in a \(tone.rawValue) tone.
        Keep the same information but adjust the style.

        Original: \(answer.answer)

        Rephrased (\(tone.rawValue)):
        """

        return try await ClaudeAPIClient.shared.predict(prompt)
    }
}

enum AnswerTone: String, CaseIterable {
    case formal = "formal"
    case casual = "casual"
    case technical = "technical"
    case simplified = "simplified"
    case diplomatic = "diplomatic"
}

// MARK: - Answer Statistics

extension LiveAnswerGenerator {
    struct AnswerStats {
        let totalAnswered: Int
        let averageDuration: TimeInterval
        let confidenceBreakdown: [AnswerConfidence: Int]
        let followUpCount: Int
    }

    private static var answerHistory: [AnswerResult] = []

    func recordAnswer(_ result: AnswerResult) {
        Self.answerHistory.append(result)

        // Keep only last 100
        if Self.answerHistory.count > 100 {
            Self.answerHistory.removeFirst(20)
        }
    }

    func getStats() -> AnswerStats {
        let history = Self.answerHistory

        let confidenceBreakdown = Dictionary(grouping: history) { $0.confidence }
            .mapValues { $0.count }

        let avgDuration = history.isEmpty ? 0 :
            history.map { $0.duration }.reduce(0, +) / Double(history.count)

        let followUps = history.filter { $0.isFollowUp }.count

        return AnswerStats(
            totalAnswered: history.count,
            averageDuration: avgDuration,
            confidenceBreakdown: confidenceBreakdown,
            followUpCount: followUps
        )
    }

    func clearStats() {
        Self.answerHistory.removeAll()
    }
}
