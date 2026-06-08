import Foundation

// MARK: - Convenience Methods

extension ClaudeAPIClient {
    /// Quick meeting summary
    func summarizeMeeting(_ transcript: String) async throws -> String {
        let prompt = """
        Summarize this meeting transcript concisely. Include:
        - Key decisions made
        - Action items with owners (if mentioned)
        - Important topics discussed

        Transcript:
        \(transcript)
        """
        return try await sendMessage(prompt, includeHistory: false)
    }

    /// Extract action items from text
    func extractActionItems(_ text: String) async throws -> String {
        let prompt = """
        Extract all action items from this text. Format as a bullet list with:
        - Task description
        - Owner (if mentioned)
        - Deadline (if mentioned)

        Text:
        \(text)
        """
        return try await predict(prompt)
    }

    /// Real-time transcription assistance
    func suggestResponse(context: String, currentSpeaker: String) async throws -> String {
        let prompt = """
        Based on this meeting context, suggest a brief, helpful response for \(currentSpeaker).
        Keep it under 2 sentences.

        Context:
        \(context)
        """
        return try await predict(prompt)
    }

    /// Configure for meeting assistant use case
    func configureForMeetings() {
        model = .claude3Haiku
        predictionMode = true
        maxTokens = 512
        setSystemPrompt("""
        You are a helpful meeting assistant. Your role is to:
        - Provide concise, actionable summaries
        - Extract key decisions and action items
        - Help participants stay focused and productive
        - Respond quickly with brief, relevant information

        Keep responses short and to the point. Use bullet points when listing items.
        """)
    }
}

// MARK: - Async Sequence for Streaming

extension ClaudeAPIClient {
    /// Returns an AsyncThrowingStream for token-by-token streaming
    func streamTokens(_ prompt: String, includeHistory: Bool = true) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    _ = try await streamResponseAsync(
                        prompt,
                        includeHistory: includeHistory,
                        onToken: { token in
                            continuation.yield(token)
                        }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Retry Logic

extension ClaudeAPIClient {
    /// Send message with automatic retry on rate limit
    func sendMessageWithRetry(
        _ prompt: String,
        maxRetries: Int = 3,
        includeHistory: Bool = true
    ) async throws -> String {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                return try await sendMessage(prompt, includeHistory: includeHistory)
            } catch ClaudeError.rateLimited {
                lastError = ClaudeError.rateLimited("Rate limited after \(attempt + 1) attempts")
                // Exponential backoff: 1s, 2s, 4s
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            } catch {
                throw error
            }
        }

        throw lastError ?? ClaudeError.rateLimited("Max retries exceeded")
    }
}
