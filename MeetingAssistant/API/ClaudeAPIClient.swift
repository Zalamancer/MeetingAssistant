import Foundation
import Security

// MARK: - Claude API Client

final class ClaudeAPIClient: @unchecked Sendable {
    static let shared = ClaudeAPIClient()

    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession
    private let keychainService = "com.meetingassistant.claude-api"
    private let keychainAccount = "api-key"

    // Conversation context
    private var conversationHistory: [Message] = []
    private var systemPrompt: String = "You are a helpful meeting assistant."
    private let maxHistoryMessages = 20

    // Configuration
    var model: Model = .claude3Haiku  // Fast model for predictions
    var maxTokens: Int = 1024
    var predictionMode: Bool = true   // Prioritize speed

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
    }

    // MARK: - API Key Management (UserDefaults - simpler access for development)

    private let apiKeyDefaultsKey = "com.meetingassistant.claude-api-key"

    func setAPIKey(_ key: String) throws {
        UserDefaults.standard.set(key, forKey: apiKeyDefaultsKey)
    }

    func getAPIKey() throws -> String {
        guard let key = UserDefaults.standard.string(forKey: apiKeyDefaultsKey),
              !key.isEmpty else {
            throw ClaudeError.apiKeyNotFound
        }
        return key
    }

    func deleteAPIKey() {
        UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
    }

    func hasAPIKey() -> Bool {
        return (try? getAPIKey()) != nil
    }

    // MARK: - Context Management

    func setSystemPrompt(_ prompt: String) {
        systemPrompt = prompt
    }

    func addToHistory(role: MessageRole, content: String) {
        conversationHistory.append(Message(role: role, content: content))

        // Trim history if too long
        if conversationHistory.count > maxHistoryMessages {
            conversationHistory.removeFirst(2) // Remove oldest pair
        }
    }

    func clearHistory() {
        conversationHistory.removeAll()
    }

    func getHistory() -> [Message] {
        conversationHistory
    }

    // MARK: - Send Message (Non-streaming)

    func sendMessage(_ prompt: String, includeHistory: Bool = true) async throws -> String {
        let apiKey = try getAPIKey()

        var messages = includeHistory ? conversationHistory : []
        messages.append(Message(role: .user, content: prompt))

        let requestBody = ClaudeRequest(
            model: model.rawValue,
            max_tokens: predictionMode ? min(maxTokens, 512) : maxTokens,
            system: systemPrompt,
            messages: messages
        )

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)

        try handleHTTPResponse(response, data: data)

        let claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)

        guard let content = claudeResponse.content.first?.text else {
            throw ClaudeError.emptyResponse
        }

        // Update history
        if includeHistory {
            addToHistory(role: .user, content: prompt)
            addToHistory(role: .assistant, content: content)
        }

        return content
    }

    // MARK: - Stream Response

    func streamResponse(
        _ prompt: String,
        includeHistory: Bool = true,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        Task {
            do {
                let fullResponse = try await streamResponseAsync(
                    prompt,
                    includeHistory: includeHistory,
                    onToken: onToken
                )
                onComplete(fullResponse)
            } catch {
                onError(error)
            }
        }
    }

    func streamResponseAsync(
        _ prompt: String,
        includeHistory: Bool = true,
        onToken: @escaping (String) -> Void
    ) async throws -> String {
        let apiKey = try getAPIKey()

        var messages = includeHistory ? conversationHistory : []
        messages.append(Message(role: .user, content: prompt))

        let requestBody = ClaudeStreamRequest(
            model: model.rawValue,
            max_tokens: predictionMode ? min(maxTokens, 512) : maxTokens,
            system: systemPrompt,
            messages: messages,
            stream: true
        )

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }

        // Check for errors before streaming
        if httpResponse.statusCode != 200 {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            try handleHTTPStatus(httpResponse.statusCode, data: errorData)
        }

        var fullResponse = ""

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }

            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let event = try? JSONDecoder().decode(StreamEvent.self, from: jsonData) else {
                continue
            }

            if event.type == "content_block_delta",
               let delta = event.delta,
               let text = delta.text {
                fullResponse += text
                onToken(text)
            }
        }

        // Update history
        if includeHistory {
            addToHistory(role: .user, content: prompt)
            addToHistory(role: .assistant, content: fullResponse)
        }

        return fullResponse
    }

    // MARK: - Quick Prediction (Optimized for Speed)

    func predict(_ prompt: String) async throws -> String {
        let previousMode = predictionMode
        let previousTokens = maxTokens
        let previousModel = model

        // Optimize for speed
        predictionMode = true
        maxTokens = 256
        model = .claude3Haiku

        defer {
            predictionMode = previousMode
            maxTokens = previousTokens
            model = previousModel
        }

        return try await sendMessage(prompt, includeHistory: false)
    }

    // MARK: - Error Handling

    private func handleHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }
        try handleHTTPStatus(httpResponse.statusCode, data: data)
    }

    private func handleHTTPStatus(_ statusCode: Int, data: Data) throws {
        switch statusCode {
        case 200...299:
            return
        case 401:
            throw ClaudeError.invalidAPIKey
        case 429:
            // Parse retry-after if available
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw ClaudeError.rateLimited(errorResponse.error.message)
            }
            throw ClaudeError.rateLimited("Rate limit exceeded. Please wait before retrying.")
        case 400, 404:
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw ClaudeError.badRequest(errorResponse.error.message)
            }
            if let errorStr = String(data: data, encoding: .utf8) {
                throw ClaudeError.badRequest("Request failed (\(statusCode)): \(errorStr)")
            }
            throw ClaudeError.badRequest("Invalid request (\(statusCode))")
        case 500...599:
            throw ClaudeError.serverError(statusCode)
        default:
            throw ClaudeError.httpError(statusCode)
        }
    }
}

// MARK: - Models

enum Model: String {
    case claude4Sonnet = "claude-sonnet-4-20250514"
    case claude35Sonnet = "claude-3-5-sonnet-20241022"
    case claude3Haiku = "claude-3-haiku-20240307"
    case claude3Sonnet = "claude-3-sonnet-20240229"
}

enum MessageRole: String, Codable {
    case user
    case assistant
}

struct Message: Codable {
    let role: MessageRole
    let content: String
}

// MARK: - Request/Response Types

private struct ClaudeRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [Message]
}

private struct ClaudeStreamRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [Message]
    let stream: Bool
}

private struct ClaudeResponse: Decodable {
    let id: String
    let content: [ContentBlock]
    let model: String
    let stop_reason: String?
    let usage: Usage?
}

private struct ContentBlock: Decodable {
    let type: String
    let text: String?
}

private struct Usage: Decodable {
    let input_tokens: Int
    let output_tokens: Int
}

private struct StreamEvent: Decodable {
    let type: String
    let delta: Delta?
}

private struct Delta: Decodable {
    let type: String?
    let text: String?
}

private struct ErrorResponse: Decodable {
    let error: ClaudeAPIErrorInfo
}

private struct ClaudeAPIErrorInfo: Decodable {
    let type: String
    let message: String
}

// MARK: - Error Types

enum ClaudeError: Error, LocalizedError {
    case apiKeyNotFound
    case invalidAPIKey
    case keychainError(OSStatus)
    case invalidResponse
    case emptyResponse
    case rateLimited(String)
    case badRequest(String)
    case serverError(Int)
    case httpError(Int)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .apiKeyNotFound:
            return "API key not found. Please set your Claude API key."
        case .invalidAPIKey:
            return "Invalid API key. Please check your Claude API key."
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .invalidResponse:
            return "Invalid response from API"
        case .emptyResponse:
            return "Empty response from API"
        case .rateLimited(let message):
            return "Rate limited: \(message)"
        case .badRequest(let message):
            return "Bad request: \(message)"
        case .serverError(let code):
            return "Server error: \(code)"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
