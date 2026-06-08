import Foundation

// MARK: - AI-Powered Context Enhancement

extension MeetingContext {
    /// Use Claude to extract topics from recent discussion
    func extractTopicsWithAI() async throws -> [String] {
        let context = getContextForPrediction()

        guard !context.isEmpty else { return [] }

        let prompt = """
        Extract the main topics being discussed from this meeting excerpt.
        Return only a comma-separated list of 2-5 key topics, nothing else.

        Meeting excerpt:
        \(context)
        """

        let response = try await ClaudeAPIClient.shared.predict(prompt)
        let topics = response
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for topic in topics {
            addTopic(topic)
        }

        return topics
    }

    /// Use Claude to extract action items from recent discussion
    func extractActionItemsWithAI() async throws -> [String] {
        let context = getContextSummary()

        guard !context.isEmpty else { return [] }

        let prompt = """
        Extract any action items, tasks, or commitments mentioned in this meeting.
        Format: One action item per line, starting with "- "
        Include assignee if mentioned (in parentheses).
        If no clear action items, respond with "None identified."

        Meeting context:
        \(context)
        """

        let response = try await ClaudeAPIClient.shared.sendMessage(prompt, includeHistory: false)

        if response.lowercased().contains("none identified") {
            return []
        }

        let items = response
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("-") || $0.hasPrefix("•") }
            .map { String($0.dropFirst(1).trimmingCharacters(in: .whitespaces)) }

        for item in items {
            // Parse assignee if present
            if let range = item.range(of: "\\(.*?\\)", options: .regularExpression) {
                let assignee = String(item[range]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                let description = item.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespaces)
                addActionItem(description, assignee: assignee)
            } else {
                addActionItem(item)
            }
        }

        return items
    }

    /// Generate a condensed summary of the meeting so far
    func generateRunningSummary() async throws -> String {
        let fullContext = getFullContext()

        guard !fullContext.transcriptions.isEmpty else {
            return "Meeting just started. No content yet."
        }

        let transcript = fullContext.transcriptions.map { $0.text }.joined(separator: " ")

        let prompt = """
        Provide a brief running summary of this meeting (2-3 sentences).
        Focus on: main discussion points, any decisions made, pending questions.

        Transcript:
        \(transcript.prefix(3000))
        """

        return try await ClaudeAPIClient.shared.predict(prompt)
    }

    /// Identify the current speaker based on context patterns
    func identifySpeaker(for text: String) async throws -> String? {
        let recentContext = getContextForPrediction()

        let prompt = """
        Based on the speaking patterns and context, who is most likely saying this?
        If you can identify a name, return just the name.
        If unsure, return "Unknown".

        Recent context:
        \(recentContext)

        New statement:
        \(text)
        """

        let response = try await ClaudeAPIClient.shared.predict(prompt)
        let speaker = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if speaker.lowercased() == "unknown" || speaker.isEmpty {
            return nil
        }

        return speaker
    }

    /// Detect if the meeting has shifted to a new topic
    func detectTopicShift(newText: String) async throws -> String? {
        let recentTopics = getFullContext().topics.suffix(3).joined(separator: ", ")

        let prompt = """
        Has the conversation shifted to a new topic?
        Current topics: \(recentTopics.isEmpty ? "None yet" : recentTopics)

        New text: \(newText)

        If there's a clear topic shift, return the new topic name only.
        If no shift, return "SAME".
        """

        let response = try await ClaudeAPIClient.shared.predict(prompt)

        if response.uppercased().contains("SAME") {
            return nil
        }

        let newTopic = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newTopic.isEmpty {
            addTopic(newTopic)
            return newTopic
        }

        return nil
    }
}

// MARK: - Context Compression

extension MeetingContext {
    /// Compress old context to save tokens while preserving key information
    func compressOldContext() async throws {
        let fullContext = getFullContext()

        guard fullContext.transcriptions.count > 10 else { return }

        // Get the older transcriptions that we want to compress
        let olderTranscriptions = Array(fullContext.transcriptions.prefix(fullContext.transcriptions.count - 5))
        let olderText = olderTranscriptions.map { $0.text }.joined(separator: " ")

        let prompt = """
        Compress this meeting segment into 2-3 key bullet points.
        Preserve: decisions made, action items, important facts.
        Be very concise.

        Segment:
        \(olderText)
        """

        let compressed = try await ClaudeAPIClient.shared.predict(prompt)

        // Store compressed summary as a topic/note
        addTopic("Earlier: \(compressed)")

        // Clear old messages now that they're compressed
        clearOldMessages()
    }
}

// MARK: - Contextual Predictions

extension MeetingContext {
    /// Predict what might be discussed next
    func predictNextTopic() async throws -> String {
        let context = getContextSummary()

        let prompt = """
        Based on the meeting flow, what topic or question might come up next?
        Give one brief prediction (1 sentence).

        Current meeting state:
        \(context)
        """

        return try await ClaudeAPIClient.shared.predict(prompt)
    }

    /// Suggest a question the user might want to ask
    func suggestQuestion() async throws -> String {
        let context = getContextForPrediction()

        let prompt = """
        Based on this meeting discussion, suggest ONE clarifying question
        that would be useful to ask. Keep it brief and relevant.

        Context:
        \(context)
        """

        return try await ClaudeAPIClient.shared.predict(prompt)
    }

    /// Generate a quick response suggestion
    func suggestResponse() async throws -> String {
        let context = getContextForPrediction()

        let prompt = """
        Based on the current discussion, suggest a brief, helpful response
        the user could give. Keep it natural and under 20 words.

        Context:
        \(context)
        """

        return try await ClaudeAPIClient.shared.predict(prompt)
    }
}
