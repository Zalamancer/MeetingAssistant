import Foundation

// MARK: - Prediction Engine

final class PredictionEngine: @unchecked Sendable {
    static let shared = PredictionEngine()

    // Configuration
    var updateInterval: TimeInterval = 12.0  // Seconds between updates
    var maxPredictions = 5
    var minConfidenceThreshold = 4
    var cacheValidityDuration: TimeInterval = 30.0  // Cache expires after 30s

    // State
    private(set) var predictions: [Prediction] = []
    private(set) var isRunning = false
    private(set) var lastUpdateTime: Date?

    // Cache
    private var cachedContextHash: Int = 0
    private var cachedPredictions: [Prediction] = []
    private var cacheTimestamp: Date?

    // Engine
    private var updateTask: Task<Void, Never>?
    private let context: MeetingContext
    private let claude = ClaudeAPIClient.shared

    // Callbacks
    var onPredictionsUpdated: (([Prediction]) -> Void)?
    var onError: ((Error) -> Void)?

    private init() {
        self.context = MeetingContext.shared
    }

    // MARK: - Start/Stop

    func start() {
        guard !isRunning else { return }
        isRunning = true

        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.isRunning else { break }

                await self.updatePredictions()

                try? await Task.sleep(nanoseconds: UInt64(self.updateInterval * 1_000_000_000))
            }
        }

        print("Prediction engine started (interval: \(updateInterval)s)")
    }

    func stop() {
        isRunning = false
        updateTask?.cancel()
        updateTask = nil
        print("Prediction engine stopped")
    }

    // MARK: - Manual Update

    func updateNow() async {
        await updatePredictions()
    }

    // MARK: - Get Predictions

    func getTopPredictions(count: Int = 3) -> [Prediction] {
        return Array(predictions
            .filter { $0.confidence >= minConfidenceThreshold }
            .sorted { $0.confidence > $1.confidence }
            .prefix(count))
    }

    func getPredictionFor(query: String) -> Prediction? {
        // Find prediction that best matches a query
        let queryWords = Set(query.lowercased().split(separator: " "))

        return predictions.max { p1, p2 in
            let words1 = Set(p1.question.lowercased().split(separator: " "))
            let words2 = Set(p2.question.lowercased().split(separator: " "))

            let overlap1 = queryWords.intersection(words1).count
            let overlap2 = queryWords.intersection(words2).count

            return overlap1 < overlap2
        }
    }

    // MARK: - Core Prediction Logic

    private func updatePredictions() async {
        // Check if context has changed
        let currentContextHash = context.getContextSummary().hashValue

        // Use cache if valid
        if let cacheTime = cacheTimestamp,
           Date().timeIntervalSince(cacheTime) < cacheValidityDuration,
           currentContextHash == cachedContextHash,
           !cachedPredictions.isEmpty {
            return  // Cache is still valid
        }

        // Get context
        let contextSummary = context.getContextSummary()
        let screenText = context.getFullContext().screenStates.last?.text ?? "No screen content"

        guard !contextSummary.isEmpty else { return }

        do {
            let newPredictions = try await generatePredictions(
                context: contextSummary,
                screenText: screenText
            )

            // Update state
            predictions = newPredictions
            lastUpdateTime = Date()

            // Update cache
            cachedContextHash = currentContextHash
            cachedPredictions = newPredictions
            cacheTimestamp = Date()

            // Notify
            await MainActor.run { [weak self] in
                self?.onPredictionsUpdated?(newPredictions)
            }

        } catch {
            await MainActor.run { [weak self] in
                self?.onError?(error)
            }
        }
    }

    private func generatePredictions(context: String, screenText: String) async throws -> [Prediction] {
        let prompt = buildPredictionPrompt(context: context, screenText: screenText)

        // Use streaming for faster first-token response
        let response = try await claude.sendMessage(prompt, includeHistory: false)

        return parsePredictions(from: response)
    }

    // MARK: - Prompt Building

    private func buildPredictionPrompt(context: String, screenText: String) -> String {
        """
        You are an AI meeting assistant. Based on this meeting transcript and screen content, predict the 3-5 most likely questions that will be asked next. For each prediction, provide:
        - Question (what they'll likely ask)
        - Answer (a concise, ready-to-use response)
        - Confidence (1-10)

        Meeting so far:
        \(context.prefix(2500))

        Screen content:
        \(screenText.prefix(800))

        Respond in JSON format only:
        {
          "predictions": [
            {"question": "...", "answer": "...", "confidence": 8},
            {"question": "...", "answer": "...", "confidence": 7}
          ]
        }
        """
    }

    // MARK: - Response Parsing

    private func parsePredictions(from response: String) -> [Prediction] {
        // Try to extract JSON from response
        guard let jsonData = extractJSON(from: response) else {
            print("Failed to extract JSON from response")
            return []
        }

        do {
            let decoded = try JSONDecoder().decode(PredictionResponse.self, from: jsonData)
            return decoded.predictions.map { item in
                Prediction(
                    id: UUID(),
                    question: item.question,
                    answer: item.answer,
                    confidence: item.confidence,
                    timestamp: Date(),
                    category: categorize(question: item.question)
                )
            }
        } catch {
            print("JSON parsing error: \(error)")
            return parsePredictionsFallback(from: response)
        }
    }

    private func extractJSON(from text: String) -> Data? {
        // Try to find JSON object in response
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code blocks if present
        if jsonString.hasPrefix("```json") {
            jsonString = String(jsonString.dropFirst(7))
        } else if jsonString.hasPrefix("```") {
            jsonString = String(jsonString.dropFirst(3))
        }

        if jsonString.hasSuffix("```") {
            jsonString = String(jsonString.dropLast(3))
        }

        jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find JSON object boundaries
        if let startIndex = jsonString.firstIndex(of: "{"),
           let endIndex = jsonString.lastIndex(of: "}") {
            let jsonSubstring = String(jsonString[startIndex...endIndex])
            return jsonSubstring.data(using: .utf8)
        }

        return jsonString.data(using: .utf8)
    }

    private func parsePredictionsFallback(from response: String) -> [Prediction] {
        // Fallback: try to parse as plain text predictions
        var predictions: [Prediction] = []

        let lines = response.split(separator: "\n")
        var currentQuestion: String?

        for line in lines {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)

            if trimmed.lowercased().contains("question") || trimmed.contains("?") {
                currentQuestion = trimmed
                    .replacingOccurrences(of: "Question:", with: "")
                    .replacingOccurrences(of: "Q:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("answer") || trimmed.lowercased().hasPrefix("a:") {
                if let question = currentQuestion {
                    let answer = trimmed
                        .replacingOccurrences(of: "Answer:", with: "")
                        .replacingOccurrences(of: "A:", with: "")
                        .trimmingCharacters(in: .whitespaces)

                    predictions.append(Prediction(
                        id: UUID(),
                        question: question,
                        answer: answer,
                        confidence: 5,
                        timestamp: Date(),
                        category: categorize(question: question)
                    ))
                    currentQuestion = nil
                }
            }
        }

        return predictions
    }

    private func categorize(question: String) -> PredictionCategory {
        let lower = question.lowercased()

        if lower.contains("when") || lower.contains("deadline") || lower.contains("timeline") {
            return .timeline
        } else if lower.contains("who") || lower.contains("responsible") || lower.contains("owner") {
            return .ownership
        } else if lower.contains("how") || lower.contains("approach") || lower.contains("method") {
            return .process
        } else if lower.contains("why") || lower.contains("reason") {
            return .rationale
        } else if lower.contains("what") || lower.contains("status") || lower.contains("update") {
            return .status
        } else if lower.contains("cost") || lower.contains("budget") || lower.contains("resource") {
            return .resources
        } else {
            return .general
        }
    }

    // MARK: - Cache Management

    func invalidateCache() {
        cachedContextHash = 0
        cachedPredictions = []
        cacheTimestamp = nil
    }

    func clearPredictions() {
        predictions = []
        invalidateCache()
    }
}

// MARK: - Data Types

struct Prediction: Identifiable, Codable {
    let id: UUID
    let question: String
    let answer: String
    let confidence: Int
    let timestamp: Date
    let category: PredictionCategory

    var confidenceLabel: String {
        switch confidence {
        case 9...10: return "Very Likely"
        case 7...8: return "Likely"
        case 5...6: return "Possible"
        default: return "Unlikely"
        }
    }
}

enum PredictionCategory: String, Codable {
    case timeline = "Timeline"
    case ownership = "Ownership"
    case process = "Process"
    case rationale = "Rationale"
    case status = "Status"
    case resources = "Resources"
    case general = "General"

    var icon: String {
        switch self {
        case .timeline: return "clock"
        case .ownership: return "person"
        case .process: return "gearshape"
        case .rationale: return "questionmark.circle"
        case .status: return "chart.bar"
        case .resources: return "dollarsign.circle"
        case .general: return "bubble.left"
        }
    }
}

// MARK: - JSON Response Types

private struct PredictionResponse: Decodable {
    let predictions: [PredictionItem]
}

private struct PredictionItem: Decodable {
    let question: String
    let answer: String
    let confidence: Int
}
