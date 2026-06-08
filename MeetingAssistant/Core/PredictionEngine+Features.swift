import Foundation

// MARK: - Advanced Prediction Features

extension PredictionEngine {
    /// Generate predictions focused on a specific topic
    func predictForTopic(_ topic: String) async throws -> [Prediction] {
        let contextSummary = MeetingContext.shared.getContextSummary()

        let prompt = """
        Based on this meeting context, predict 3 questions specifically about "\(topic)".
        Include ready-to-use answers.

        Context:
        \(contextSummary.prefix(2000))

        Respond in JSON:
        {"predictions": [{"question": "...", "answer": "...", "confidence": 8}]}
        """

        let response = try await ClaudeAPIClient.shared.sendMessage(prompt, includeHistory: false)

        guard let jsonData = response.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PredictionResponse.self, from: jsonData) else {
            return []
        }

        return decoded.predictions.map { item in
            Prediction(
                id: UUID(),
                question: item.question,
                answer: item.answer,
                confidence: item.confidence,
                timestamp: Date(),
                category: .general
            )
        }
    }

    /// Get an instant answer for an ad-hoc question
    func getInstantAnswer(for question: String) async throws -> String {
        let context = MeetingContext.shared.getContextForPrediction()

        // First check if we have a cached prediction
        if let cached = getPredictionFor(query: question) {
            return cached.answer
        }

        // Generate new answer
        let prompt = """
        Based on this meeting context, answer this question concisely:

        Question: \(question)

        Context:
        \(context)

        Provide a direct, helpful answer in 1-2 sentences.
        """

        return try await ClaudeAPIClient.shared.predict(prompt)
    }

    /// Generate follow-up questions for deeper discussion
    func generateFollowUpQuestions() async throws -> [String] {
        let context = MeetingContext.shared.getContextSummary()

        let prompt = """
        Based on this meeting discussion, suggest 3 follow-up questions
        that would help clarify or deepen the discussion.
        Return just the questions, one per line.

        Context:
        \(context.prefix(1500))
        """

        let response = try await ClaudeAPIClient.shared.predict(prompt)

        return response
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.contains("?") }
            .map { String($0) }
    }

    /// Predict potential objections or concerns
    func predictObjections() async throws -> [Prediction] {
        let context = MeetingContext.shared.getContextSummary()

        let prompt = """
        Based on this meeting context, predict 2-3 potential objections or concerns
        that might be raised, and prepare responses.

        Context:
        \(context.prefix(2000))

        Respond in JSON:
        {"predictions": [{"question": "Objection/concern...", "answer": "Response...", "confidence": 7}]}
        """

        let response = try await ClaudeAPIClient.shared.sendMessage(prompt, includeHistory: false)

        guard let jsonData = extractJSONData(from: response),
              let decoded = try? JSONDecoder().decode(PredictionResponse.self, from: jsonData) else {
            return []
        }

        return decoded.predictions.map { item in
            Prediction(
                id: UUID(),
                question: item.question,
                answer: item.answer,
                confidence: item.confidence,
                timestamp: Date(),
                category: .rationale
            )
        }
    }

    private func extractJSONData(from text: String) -> Data? {
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code blocks
        if jsonString.contains("```") {
            jsonString = jsonString
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = jsonString.firstIndex(of: "{"),
           let end = jsonString.lastIndex(of: "}") {
            return String(jsonString[start...end]).data(using: .utf8)
        }

        return nil
    }
}

// Response type for extension methods
private struct PredictionResponse: Decodable {
    let predictions: [PredictionItem]

    struct PredictionItem: Decodable {
        let question: String
        let answer: String
        let confidence: Int
    }
}

// MARK: - Quick Response Generator

final class QuickResponseGenerator {
    static let shared = QuickResponseGenerator()

    private let claude = ClaudeAPIClient.shared
    private var responseCache: [String: CachedResponse] = [:]
    private let cacheExpiry: TimeInterval = 60.0  // 1 minute

    private init() {}

    struct CachedResponse {
        let response: String
        let timestamp: Date
    }

    /// Generate a quick response to use in the meeting
    func generateResponse(for situation: ResponseSituation) async throws -> String {
        let cacheKey = situation.rawValue

        // Check cache
        if let cached = responseCache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpiry {
            return cached.response
        }

        let context = MeetingContext.shared.getContextForPrediction()
        let prompt = buildPrompt(for: situation, context: context)

        let response = try await claude.predict(prompt)

        // Cache it
        responseCache[cacheKey] = CachedResponse(response: response, timestamp: Date())

        return response
    }

    private func buildPrompt(for situation: ResponseSituation, context: String) -> String {
        let baseContext = "Meeting context:\n\(context)\n\n"

        switch situation {
        case .needMoreTime:
            return baseContext + "Generate a polite response asking for more time to think about this. Keep it under 15 words."

        case .agreeWithCaveat:
            return baseContext + "Generate a response agreeing but noting a small concern. Keep it under 20 words."

        case .requestClarification:
            return baseContext + "Generate a polite request for clarification on the last point. Keep it under 15 words."

        case .summarizeSoFar:
            return baseContext + "Summarize the key points discussed so far in 2 sentences."

        case .suggestNextSteps:
            return baseContext + "Suggest logical next steps based on the discussion. Keep it brief."

        case .tableForLater:
            return baseContext + "Generate a response suggesting to table this topic for later. Keep it polite and brief."

        case .volunteer:
            return baseContext + "Generate a response volunteering to take on the discussed task. Keep it brief and enthusiastic."

        case .delegate:
            return baseContext + "Generate a response suggesting someone else might be better suited. Keep it diplomatic."
        }
    }

    func clearCache() {
        responseCache.removeAll()
    }
}

enum ResponseSituation: String, CaseIterable {
    case needMoreTime = "need_more_time"
    case agreeWithCaveat = "agree_with_caveat"
    case requestClarification = "request_clarification"
    case summarizeSoFar = "summarize"
    case suggestNextSteps = "next_steps"
    case tableForLater = "table_for_later"
    case volunteer = "volunteer"
    case delegate = "delegate"

    var displayName: String {
        switch self {
        case .needMoreTime: return "Need More Time"
        case .agreeWithCaveat: return "Agree (with caveat)"
        case .requestClarification: return "Ask for Clarification"
        case .summarizeSoFar: return "Summarize Discussion"
        case .suggestNextSteps: return "Suggest Next Steps"
        case .tableForLater: return "Table for Later"
        case .volunteer: return "Volunteer"
        case .delegate: return "Suggest Someone Else"
        }
    }

    var icon: String {
        switch self {
        case .needMoreTime: return "clock"
        case .agreeWithCaveat: return "checkmark.circle"
        case .requestClarification: return "questionmark.circle"
        case .summarizeSoFar: return "list.bullet"
        case .suggestNextSteps: return "arrow.right.circle"
        case .tableForLater: return "pause.circle"
        case .volunteer: return "hand.raised"
        case .delegate: return "person.badge.plus"
        }
    }
}

// MARK: - Prediction Analytics

extension PredictionEngine {
    struct PredictionStats {
        let totalGenerated: Int
        let averageConfidence: Double
        let categoryBreakdown: [PredictionCategory: Int]
        let lastUpdateAge: TimeInterval?
    }

    func getStats() -> PredictionStats {
        let categories = Dictionary(grouping: predictions) { $0.category }
            .mapValues { $0.count }

        let avgConfidence = predictions.isEmpty ? 0 :
            Double(predictions.map { $0.confidence }.reduce(0, +)) / Double(predictions.count)

        let updateAge = lastUpdateTime.map { Date().timeIntervalSince($0) }

        return PredictionStats(
            totalGenerated: predictions.count,
            averageConfidence: avgConfidence,
            categoryBreakdown: categories,
            lastUpdateAge: updateAge
        )
    }
}
