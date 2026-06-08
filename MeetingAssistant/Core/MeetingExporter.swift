import Foundation
import AppKit

// MARK: - Meeting Exporter

final class MeetingExporter {
    static let shared = MeetingExporter()

    private let claude = ClaudeAPIClient.shared

    // MARK: - Export Result Types

    struct ExportResult {
        let meetingNotes: MeetingNotes
        let emailDraft: EmailDraft
        let actionItems: [ExportedActionItem]
        let exportDate: Date

        var markdownContent: String {
            meetingNotes.markdown
        }

        var plainTextContent: String {
            meetingNotes.plainText
        }
    }

    struct MeetingNotes {
        let title: String
        let date: Date
        let duration: TimeInterval
        let participants: [String]
        let summary: String
        let keyDecisions: [String]
        let actionItems: [ExportedActionItem]
        let questionsDiscussed: [QuestionAnswer]
        let nextSteps: [String]
        let fullTranscript: String?

        var markdown: String {
            var md = "# \(title)\n\n"

            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .short

            md += "**Date:** \(formatter.string(from: date))\n"
            md += "**Duration:** \(formattedDuration)\n"

            if !participants.isEmpty {
                md += "**Participants:** \(participants.joined(separator: ", "))\n"
            }

            md += "\n---\n\n"

            // Summary
            md += "## Summary\n\n"
            md += "\(summary)\n\n"

            // Key Decisions
            if !keyDecisions.isEmpty {
                md += "## Key Decisions\n\n"
                for decision in keyDecisions {
                    md += "- \(decision)\n"
                }
                md += "\n"
            }

            // Action Items
            if !actionItems.isEmpty {
                md += "## Action Items\n\n"
                for item in actionItems {
                    var line = "- [ ] \(item.description)"
                    if let owner = item.owner {
                        line += " **(@\(owner))**"
                    }
                    if let due = item.dueDate {
                        let df = DateFormatter()
                        df.dateStyle = .short
                        line += " - Due: \(df.string(from: due))"
                    }
                    md += "\(line)\n"
                }
                md += "\n"
            }

            // Questions & Answers
            if !questionsDiscussed.isEmpty {
                md += "## Questions Discussed\n\n"
                for qa in questionsDiscussed {
                    md += "### Q: \(qa.question)\n"
                    md += "\(qa.answer)\n\n"
                }
            }

            // Next Steps
            if !nextSteps.isEmpty {
                md += "## Next Steps\n\n"
                for (index, step) in nextSteps.enumerated() {
                    md += "\(index + 1). \(step)\n"
                }
                md += "\n"
            }

            // Transcript (optional)
            if let transcript = fullTranscript, !transcript.isEmpty {
                md += "---\n\n"
                md += "<details>\n<summary>Full Transcript</summary>\n\n"
                md += "```\n\(transcript)\n```\n"
                md += "</details>\n"
            }

            return md
        }

        var plainText: String {
            var text = "\(title)\n"
            text += String(repeating: "=", count: title.count) + "\n\n"

            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .short

            text += "Date: \(formatter.string(from: date))\n"
            text += "Duration: \(formattedDuration)\n"

            if !participants.isEmpty {
                text += "Participants: \(participants.joined(separator: ", "))\n"
            }

            text += "\n" + String(repeating: "-", count: 40) + "\n\n"

            // Summary
            text += "SUMMARY\n\n"
            text += "\(summary)\n\n"

            // Key Decisions
            if !keyDecisions.isEmpty {
                text += "KEY DECISIONS\n\n"
                for decision in keyDecisions {
                    text += "* \(decision)\n"
                }
                text += "\n"
            }

            // Action Items
            if !actionItems.isEmpty {
                text += "ACTION ITEMS\n\n"
                for item in actionItems {
                    var line = "[ ] \(item.description)"
                    if let owner = item.owner {
                        line += " (@\(owner))"
                    }
                    text += "\(line)\n"
                }
                text += "\n"
            }

            // Questions & Answers
            if !questionsDiscussed.isEmpty {
                text += "QUESTIONS DISCUSSED\n\n"
                for qa in questionsDiscussed {
                    text += "Q: \(qa.question)\n"
                    text += "A: \(qa.answer)\n\n"
                }
            }

            // Next Steps
            if !nextSteps.isEmpty {
                text += "NEXT STEPS\n\n"
                for (index, step) in nextSteps.enumerated() {
                    text += "\(index + 1). \(step)\n"
                }
            }

            return text
        }

        private var formattedDuration: String {
            let hours = Int(duration) / 3600
            let minutes = Int(duration) / 60 % 60

            if hours > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(minutes) minutes"
        }
    }

    struct EmailDraft {
        let subject: String
        let recipients: [String]
        let body: String
        let htmlBody: String

        var attributedBody: NSAttributedString {
            if let data = htmlBody.data(using: .utf8),
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [
                       .documentType: NSAttributedString.DocumentType.html,
                       .characterEncoding: String.Encoding.utf8.rawValue
                   ],
                   documentAttributes: nil
               ) {
                return attributed
            }
            return NSAttributedString(string: body)
        }
    }

    struct ExportedActionItem: Codable, Identifiable {
        let id: UUID
        let description: String
        let owner: String?
        let dueDate: Date?
        let priority: Priority

        enum Priority: String, Codable {
            case high = "High"
            case medium = "Medium"
            case low = "Low"
        }

        init(description: String, owner: String? = nil, dueDate: Date? = nil, priority: Priority = .medium) {
            self.id = UUID()
            self.description = description
            self.owner = owner
            self.dueDate = dueDate
            self.priority = priority
        }
    }

    struct QuestionAnswer: Codable {
        let question: String
        let answer: String
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Export Generation

    func generateExport(
        from context: FullMeetingContext,
        meetingInfo: MeetingInfo,
        predictions: [Prediction] = []
    ) async throws -> ExportResult {
        // Build the full transcript
        let transcript = buildTranscript(from: context)

        // Generate AI-powered notes
        let aiResponse = try await generateAINotes(
            transcript: transcript,
            metadata: context.metadata,
            existingActionItems: context.actionItems
        )

        // Parse the AI response
        let parsedNotes = parseAIResponse(aiResponse, context: context, meetingInfo: meetingInfo)

        // Generate email draft
        let emailDraft = try await generateEmailDraft(
            notes: parsedNotes,
            meetingInfo: meetingInfo
        )

        return ExportResult(
            meetingNotes: parsedNotes,
            emailDraft: emailDraft,
            actionItems: parsedNotes.actionItems,
            exportDate: Date()
        )
    }

    private func buildTranscript(from context: FullMeetingContext) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        return context.transcriptions.map { entry in
            let time = formatter.string(from: entry.timestamp)
            let speaker = entry.speaker ?? "Speaker"
            return "[\(time)] \(speaker): \(entry.text)"
        }.joined(separator: "\n")
    }

    private func generateAINotes(
        transcript: String,
        metadata: MeetingMetadata,
        existingActionItems: [ActionItem]
    ) async throws -> String {
        let existingItems = existingActionItems.map { "- \($0.description)" }.joined(separator: "\n")

        let prompt = """
        Generate professional meeting notes from this transcript:

        MEETING INFO:
        Title: \(metadata.title ?? "Team Meeting")
        Date: \(metadata.startTime?.formatted() ?? "Today")
        Participants: \(metadata.participants.joined(separator: ", "))

        TRANSCRIPT:
        \(transcript.prefix(8000))

        EXISTING ACTION ITEMS IDENTIFIED:
        \(existingItems.isEmpty ? "None yet" : existingItems)

        Please generate comprehensive meeting notes in the following JSON format:
        {
            "summary": "2-3 sentence summary of the meeting",
            "keyDecisions": ["decision 1", "decision 2"],
            "actionItems": [
                {"description": "task", "owner": "name or null", "priority": "high/medium/low"}
            ],
            "questionsDiscussed": [
                {"question": "Q", "answer": "A"}
            ],
            "nextSteps": ["step 1", "step 2"]
        }

        Focus on:
        - Extracting concrete action items with owners when mentioned
        - Identifying key decisions made
        - Capturing important Q&A exchanges
        - Summarizing next steps and follow-ups

        Return ONLY the JSON, no other text.
        """

        return try await claude.sendMessage(prompt, includeHistory: false)
    }

    private func parseAIResponse(
        _ response: String,
        context: FullMeetingContext,
        meetingInfo: MeetingInfo
    ) -> MeetingNotes {
        // Try to parse JSON response
        guard let jsonData = extractJSON(from: response),
              let parsed = try? JSONDecoder().decode(AINotesResponse.self, from: jsonData) else {
            // Fallback to basic notes if parsing fails
            return createFallbackNotes(context: context, meetingInfo: meetingInfo)
        }

        let duration: TimeInterval
        if let start = context.metadata.startTime {
            duration = (context.metadata.endTime ?? Date()).timeIntervalSince(start)
        } else {
            duration = 0
        }

        let actionItems = parsed.actionItems.map { item in
            ExportedActionItem(
                description: item.description,
                owner: item.owner,
                dueDate: nil,
                priority: ExportedActionItem.Priority(rawValue: item.priority ?? "medium") ?? .medium
            )
        }

        // Build transcript for inclusion
        let transcript = buildTranscript(from: context)

        return MeetingNotes(
            title: meetingInfo.title,
            date: meetingInfo.startTime,
            duration: duration,
            participants: meetingInfo.participants,
            summary: parsed.summary,
            keyDecisions: parsed.keyDecisions,
            actionItems: actionItems,
            questionsDiscussed: parsed.questionsDiscussed,
            nextSteps: parsed.nextSteps,
            fullTranscript: transcript.isEmpty ? nil : transcript
        )
    }

    private func createFallbackNotes(
        context: FullMeetingContext,
        meetingInfo: MeetingInfo
    ) -> MeetingNotes {
        let duration: TimeInterval
        if let start = context.metadata.startTime {
            duration = (context.metadata.endTime ?? Date()).timeIntervalSince(start)
        } else {
            duration = 0
        }

        let actionItems = context.actionItems.map { item in
            ExportedActionItem(
                description: item.description,
                owner: item.assignee,
                dueDate: item.dueDate,
                priority: .medium
            )
        }

        return MeetingNotes(
            title: meetingInfo.title,
            date: meetingInfo.startTime,
            duration: duration,
            participants: meetingInfo.participants,
            summary: "Meeting notes for \(meetingInfo.title). See transcript below for details.",
            keyDecisions: context.keyDecisions,
            actionItems: actionItems,
            questionsDiscussed: [],
            nextSteps: [],
            fullTranscript: buildTranscript(from: context)
        )
    }

    private func extractJSON(from text: String) -> Data? {
        var jsonString = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code blocks
        if jsonString.hasPrefix("```json") {
            jsonString = String(jsonString.dropFirst(7))
        } else if jsonString.hasPrefix("```") {
            jsonString = String(jsonString.dropFirst(3))
        }

        if jsonString.hasSuffix("```") {
            jsonString = String(jsonString.dropLast(3))
        }

        jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find JSON boundaries
        if let startIndex = jsonString.firstIndex(of: "{"),
           let endIndex = jsonString.lastIndex(of: "}") {
            let jsonSubstring = String(jsonString[startIndex...endIndex])
            return jsonSubstring.data(using: .utf8)
        }

        return nil
    }

    // MARK: - Email Generation

    private func generateEmailDraft(
        notes: MeetingNotes,
        meetingInfo: MeetingInfo
    ) async throws -> EmailDraft {
        let prompt = """
        Generate a professional follow-up email for this meeting.

        Meeting: \(notes.title)
        Summary: \(notes.summary)

        Key Decisions:
        \(notes.keyDecisions.map { "- \($0)" }.joined(separator: "\n"))

        Action Items:
        \(notes.actionItems.map { item in
            var line = "- \(item.description)"
            if let owner = item.owner { line += " (@\(owner))" }
            return line
        }.joined(separator: "\n"))

        Next Steps:
        \(notes.nextSteps.map { "- \($0)" }.joined(separator: "\n"))

        Generate a concise, professional follow-up email in JSON format:
        {
            "subject": "Follow-up: Meeting Title",
            "body": "Plain text email body"
        }

        The email should:
        - Thank participants
        - Summarize key points
        - List action items with owners
        - Mention next steps
        - Be professional but friendly

        Return ONLY the JSON.
        """

        let response = try await claude.sendMessage(prompt, includeHistory: false)

        // Parse email response
        if let jsonData = extractJSON(from: response),
           let parsed = try? JSONDecoder().decode(AIEmailResponse.self, from: jsonData) {
            return EmailDraft(
                subject: parsed.subject,
                recipients: meetingInfo.participants,
                body: parsed.body,
                htmlBody: convertToHTML(parsed.body)
            )
        }

        // Fallback email
        return createFallbackEmail(notes: notes, meetingInfo: meetingInfo)
    }

    private func createFallbackEmail(
        notes: MeetingNotes,
        meetingInfo: MeetingInfo
    ) -> EmailDraft {
        let subject = "Follow-up: \(notes.title)"

        var body = "Hi Team,\n\n"
        body += "Thank you for attending today's meeting. Here's a quick summary:\n\n"
        body += "Summary:\n\(notes.summary)\n\n"

        if !notes.actionItems.isEmpty {
            body += "Action Items:\n"
            for item in notes.actionItems {
                var line = "- \(item.description)"
                if let owner = item.owner {
                    line += " (@\(owner))"
                }
                body += "\(line)\n"
            }
            body += "\n"
        }

        if !notes.nextSteps.isEmpty {
            body += "Next Steps:\n"
            for step in notes.nextSteps {
                body += "- \(step)\n"
            }
            body += "\n"
        }

        body += "Please let me know if you have any questions or if I missed anything.\n\n"
        body += "Best regards"

        return EmailDraft(
            subject: subject,
            recipients: meetingInfo.participants,
            body: body,
            htmlBody: convertToHTML(body)
        )
    }

    private func convertToHTML(_ text: String) -> String {
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 14px; line-height: 1.5; }
                h1 { font-size: 18px; }
                h2 { font-size: 16px; }
                ul { padding-left: 20px; }
                .action-item { margin: 5px 0; }
                .owner { color: #0066cc; font-weight: 500; }
            </style>
        </head>
        <body>
        """

        // Convert text to HTML
        let paragraphs = text.components(separatedBy: "\n\n")
        for paragraph in paragraphs {
            let lines = paragraph.components(separatedBy: "\n")

            if lines.first?.hasSuffix(":") == true {
                // Section header
                html += "<p><strong>\(lines.first!)</strong></p>\n"
                if lines.count > 1 {
                    html += "<ul>\n"
                    for line in lines.dropFirst() {
                        let cleanLine = line.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "- ", with: "")
                        html += "<li>\(cleanLine)</li>\n"
                    }
                    html += "</ul>\n"
                }
            } else {
                html += "<p>\(paragraph.replacingOccurrences(of: "\n", with: "<br>"))</p>\n"
            }
        }

        html += "</body></html>"
        return html
    }

    // MARK: - Export Actions

    func copyToClipboard(_ content: String, format: ExportFormat = .plainText) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch format {
        case .plainText:
            pasteboard.setString(content, forType: .string)
        case .markdown:
            pasteboard.setString(content, forType: .string)
            // Also set as rich text if possible
            if let rtfData = convertMarkdownToRTF(content) {
                pasteboard.setData(rtfData, forType: .rtf)
            }
        case .html:
            pasteboard.setString(content, forType: .string)
            if let htmlData = content.data(using: .utf8) {
                pasteboard.setData(htmlData, forType: .html)
            }
        }
    }

    func copyActionItems(_ items: [ExportedActionItem]) {
        let text = items.map { item in
            var line = "[ ] \(item.description)"
            if let owner = item.owner {
                line += " (@\(owner))"
            }
            return line
        }.joined(separator: "\n")

        copyToClipboard(text)
    }

    private func convertMarkdownToRTF(_ markdown: String) -> Data? {
        // Simple markdown to RTF conversion
        var rtf = "{\\rtf1\\ansi\\deff0 "

        let lines = markdown.components(separatedBy: "\n")
        for line in lines {
            var processedLine = line

            // Headers
            if line.hasPrefix("# ") {
                processedLine = "{\\b\\fs32 \(line.dropFirst(2))}\\par"
            } else if line.hasPrefix("## ") {
                processedLine = "{\\b\\fs28 \(line.dropFirst(3))}\\par"
            } else if line.hasPrefix("### ") {
                processedLine = "{\\b\\fs24 \(line.dropFirst(4))}\\par"
            } else if line.hasPrefix("- ") {
                processedLine = "\\bullet  \(line.dropFirst(2))\\par"
            } else {
                processedLine = "\(line)\\par"
            }

            // Bold
            processedLine = processedLine.replacingOccurrences(
                of: "\\*\\*(.+?)\\*\\*",
                with: "{\\b $1}",
                options: .regularExpression
            )

            rtf += processedLine + "\n"
        }

        rtf += "}"
        return rtf.data(using: .utf8)
    }

    // MARK: - Save to File

    func saveToFile(
        _ content: String,
        filename: String,
        format: ExportFormat,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = filename
        savePanel.allowedContentTypes = [format.contentType]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else {
                completion(.failure(ExportError.cancelled))
                return
            }

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                completion(.success(url))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func saveMarkdownNotes(
        _ notes: MeetingNotes,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: notes.date)
        let safeTitle = notes.title.replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let filename = "meeting-notes-\(dateStr)-\(safeTitle).md"

        saveToFile(notes.markdown, filename: filename, format: .markdown, completion: completion)
    }

    // MARK: - Open in Mail

    func openInMail(_ emailDraft: EmailDraft) {
        let recipients = emailDraft.recipients.joined(separator: ",")
        let subject = emailDraft.subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let body = emailDraft.body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        let urlString = "mailto:\(recipients)?subject=\(subject)&body=\(body)"

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func openInMailWithHTML(_ emailDraft: EmailDraft) {
        // For HTML emails, we need to use AppleScript or a more complex approach
        // For now, fall back to plain text
        openInMail(emailDraft)
    }

    // MARK: - Quick Export

    func quickExportToClipboard(from context: FullMeetingContext, meetingInfo: MeetingInfo) async throws {
        let result = try await generateExport(from: context, meetingInfo: meetingInfo)
        copyToClipboard(result.markdownContent, format: .markdown)
    }

    func quickExportActionItems(from context: FullMeetingContext) {
        let items = context.actionItems.map { item in
            ExportedActionItem(
                description: item.description,
                owner: item.assignee,
                dueDate: item.dueDate,
                priority: .medium
            )
        }
        copyActionItems(items)
    }
}

// MARK: - Export Format

enum ExportFormat {
    case plainText
    case markdown
    case html

    var fileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .markdown: return "md"
        case .html: return "html"
        }
    }

    var contentType: UTType {
        switch self {
        case .plainText: return .plainText
        case .markdown: return .plainText  // macOS doesn't have a native markdown UTType
        case .html: return .html
        }
    }
}

// MARK: - Export Errors

enum ExportError: Error, LocalizedError {
    case cancelled
    case invalidContent
    case aiGenerationFailed
    case saveFailed(Error)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Export was cancelled"
        case .invalidContent:
            return "Invalid content for export"
        case .aiGenerationFailed:
            return "Failed to generate AI notes"
        case .saveFailed(let error):
            return "Failed to save: \(error.localizedDescription)"
        }
    }
}

// MARK: - AI Response Types

private struct AINotesResponse: Decodable {
    let summary: String
    let keyDecisions: [String]
    let actionItems: [AIActionItem]
    let questionsDiscussed: [MeetingExporter.QuestionAnswer]
    let nextSteps: [String]
}

private struct AIActionItem: Decodable {
    let description: String
    let owner: String?
    let priority: String?
}

private struct AIEmailResponse: Decodable {
    let subject: String
    let body: String
}

// MARK: - UTType Extension

import UniformTypeIdentifiers
