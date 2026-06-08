import Foundation
import Security

// MARK: - Whisper API Client

final class WhisperAPIClient: @unchecked Sendable {
    private let baseURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let session: URLSession

    private let keychainService = "com.meetingassistant.openai-api"
    private let keychainAccount = "api-key"

    // Rate limiting
    private var lastRequestTime = Date.distantPast
    private let minRequestInterval: TimeInterval = 0.5  // Max 2 requests/second

    // Configuration
    var model: WhisperModel = .whisper1
    var language: String? = "en"
    var responseFormat: ResponseFormat = .text

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    // MARK: - API Key Management (UserDefaults - simpler access for development)

    private let apiKeyDefaultsKey = "com.meetingassistant.openai-api-key"

    func setAPIKey(_ key: String) throws {
        UserDefaults.standard.set(key, forKey: apiKeyDefaultsKey)
    }

    func getAPIKey() throws -> String {
        guard let key = UserDefaults.standard.string(forKey: apiKeyDefaultsKey),
              !key.isEmpty else {
            throw WhisperError.apiKeyNotFound
        }
        return key
    }

    func deleteAPIKey() {
        UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
    }

    func hasAPIKey() -> Bool {
        return (try? getAPIKey()) != nil
    }

    // MARK: - Transcription

    func transcribe(audioData: Data, prompt: String? = nil) async throws -> String {
        let apiKey = try getAPIKey()

        // Rate limiting
        let timeSinceLastRequest = Date().timeIntervalSince(lastRequestTime)
        if timeSinceLastRequest < minRequestInterval {
            try await Task.sleep(nanoseconds: UInt64((minRequestInterval - timeSinceLastRequest) * 1_000_000_000))
        }
        lastRequestTime = Date()

        // Build multipart form data
        let boundary = UUID().uuidString
        var body = Data()

        // Audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model.rawValue)\r\n".data(using: .utf8)!)

        // Response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(responseFormat.rawValue)\r\n".data(using: .utf8)!)

        // Language (optional)
        if let language = language {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }

        // Prompt (optional - helps with context)
        if let prompt = prompt {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(prompt)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        // Create request
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Make request
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.invalidResponse
        }

        // Handle errors
        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw WhisperError.invalidAPIKey
        case 429:
            throw WhisperError.rateLimited
        case 400:
            if let errorResponse = try? JSONDecoder().decode(OpenAIError.self, from: data) {
                throw WhisperError.badRequest(errorResponse.error.message)
            }
            throw WhisperError.badRequest("Invalid request")
        default:
            throw WhisperError.httpError(httpResponse.statusCode)
        }

        // Parse response based on format
        switch responseFormat {
        case .text:
            guard let text = String(data: data, encoding: .utf8) else {
                throw WhisperError.invalidResponse
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)

        case .json, .verboseJson:
            let response = try JSONDecoder().decode(WhisperResponse.self, from: data)
            return response.text

        case .srt, .vtt:
            guard let text = String(data: data, encoding: .utf8) else {
                throw WhisperError.invalidResponse
            }
            return text
        }
    }

    // MARK: - Transcribe from file

    func transcribe(fileURL: URL, prompt: String? = nil) async throws -> String {
        let audioData = try Data(contentsOf: fileURL)
        return try await transcribe(audioData: audioData, prompt: prompt)
    }
}

// MARK: - Models

enum WhisperModel: String {
    case whisper1 = "whisper-1"
}

enum ResponseFormat: String {
    case text = "text"
    case json = "json"
    case verboseJson = "verbose_json"
    case srt = "srt"
    case vtt = "vtt"
}

// MARK: - Response Types

private struct WhisperResponse: Decodable {
    let text: String
    let language: String?
    let duration: Double?
    let segments: [Segment]?

    struct Segment: Decodable {
        let id: Int
        let start: Double
        let end: Double
        let text: String
    }
}

private struct OpenAIError: Decodable {
    let error: ErrorDetail

    struct ErrorDetail: Decodable {
        let message: String
        let type: String?
        let code: String?
    }
}

// MARK: - Errors

enum WhisperError: Error, LocalizedError {
    case apiKeyNotFound
    case invalidAPIKey
    case keychainError(OSStatus)
    case invalidResponse
    case rateLimited
    case badRequest(String)
    case httpError(Int)
    case audioTooShort
    case audioTooLong

    var errorDescription: String? {
        switch self {
        case .apiKeyNotFound:
            return "OpenAI API key not found. Please set your API key."
        case .invalidAPIKey:
            return "Invalid OpenAI API key."
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .invalidResponse:
            return "Invalid response from Whisper API."
        case .rateLimited:
            return "Rate limited. Please wait before retrying."
        case .badRequest(let message):
            return "Bad request: \(message)"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .audioTooShort:
            return "Audio clip is too short for transcription."
        case .audioTooLong:
            return "Audio clip exceeds maximum length (25MB)."
        }
    }
}
