import SwiftUI

// MARK: - Meeting Notes View

struct MeetingNotesView: View {
    let notes: MeetingExporter.MeetingNotes
    let emailDraft: MeetingExporter.EmailDraft?

    @State private var selectedTab: NotesTab = .summary
    @State private var showCopiedFeedback = false
    @State private var isSaving = false

    private let exporter = MeetingExporter.shared

    enum NotesTab: String, CaseIterable {
        case summary = "Summary"
        case actionItems = "Actions"
        case transcript = "Transcript"
        case email = "Email"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Tab selector
            tabSelector

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .summary:
                        summaryContent
                    case .actionItems:
                        actionItemsContent
                    case .transcript:
                        transcriptContent
                    case .email:
                        emailContent
                    }
                }
                .padding()
            }

            Divider()

            // Footer with actions
            footer
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(notes.title)
                    .font(.headline)

                HStack(spacing: 12) {
                    Label(formattedDate, systemImage: "calendar")
                    Label(formattedDuration, systemImage: "clock")
                    if !notes.participants.isEmpty {
                        Label("\(notes.participants.count) participants", systemImage: "person.2")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Quick stats
            HStack(spacing: 16) {
                StatBadge(value: notes.actionItems.count, label: "Actions", color: .orange)
                StatBadge(value: notes.keyDecisions.count, label: "Decisions", color: .blue)
            }
        }
        .padding()
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: notes.date)
    }

    private var formattedDuration: String {
        let minutes = Int(notes.duration / 60)
        return "\(minutes) min"
    }

    // MARK: - Tab Selector

    private var tabSelector: some View {
        HStack(spacing: 0) {
            ForEach(NotesTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(tab.rawValue)
                        .font(.subheadline)
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.1) : Color.clear)
                        .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Summary Content

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Summary
            Section {
                Text(notes.summary)
                    .font(.body)
            } header: {
                NotesSectionHeader(title: "Summary", icon: "doc.text")
            }

            // Key Decisions
            if !notes.keyDecisions.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes.keyDecisions, id: \.self) { decision in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text(decision)
                                    .font(.body)
                            }
                        }
                    }
                } header: {
                    NotesSectionHeader(title: "Key Decisions", icon: "checkmark.seal")
                }
            }

            // Next Steps
            if !notes.nextSteps.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(notes.nextSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).")
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                Text(step)
                            }
                        }
                    }
                } header: {
                    NotesSectionHeader(title: "Next Steps", icon: "arrow.right.circle")
                }
            }

            // Questions Discussed
            if !notes.questionsDiscussed.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(notes.questionsDiscussed.enumerated()), id: \.offset) { _, qa in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Q: \(qa.question)")
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text(qa.answer)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 20)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    NotesSectionHeader(title: "Questions Discussed", icon: "questionmark.circle")
                }
            }
        }
    }

    // MARK: - Action Items Content

    private var actionItemsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if notes.actionItems.isEmpty {
                EmptyStateView(
                    title: "No Action Items",
                    icon: "checkmark.circle",
                    message: "No action items were identified in this meeting."
                )
            } else {
                ForEach(notes.actionItems) { item in
                    ActionItemRow(item: item)
                }

                // Copy all button
                Button(action: copyActionItems) {
                    Label("Copy All Action Items", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Transcript Content

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let transcript = notes.fullTranscript, !transcript.isEmpty {
                Text(transcript)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
            } else {
                EmptyStateView(
                    title: "No Transcript",
                    icon: "text.bubble",
                    message: "No transcript was captured for this meeting."
                )
            }
        }
    }

    // MARK: - Email Content

    private var emailContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let email = emailDraft {
                VStack(alignment: .leading, spacing: 12) {
                    // Subject
                    HStack {
                        Text("Subject:")
                            .fontWeight(.medium)
                        Text(email.subject)
                    }

                    // Recipients
                    if !email.recipients.isEmpty {
                        HStack(alignment: .top) {
                            Text("To:")
                                .fontWeight(.medium)
                            Text(email.recipients.joined(separator: ", "))
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // Body
                    Text(email.body)
                        .textSelection(.enabled)
                        .padding()
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                }

                // Email actions
                HStack(spacing: 12) {
                    Button(action: { openInMail(email) }) {
                        Label("Open in Mail", systemImage: "envelope")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: { copyEmail(email) }) {
                        Label("Copy Email", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            } else {
                EmptyStateView(
                    title: "No Email Draft",
                    icon: "envelope",
                    message: "Email draft will be generated when you export the meeting."
                )
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Export format buttons
            Menu {
                Button("Copy as Markdown") { copyAsMarkdown() }
                Button("Copy as Plain Text") { copyAsPlainText() }
                Divider()
                Button("Save as Markdown...") { saveAsMarkdown() }
                Button("Save as Text...") { saveAsText() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderedButton)

            Spacer()

            // Feedback
            if showCopiedFeedback {
                Text("Copied!")
                    .font(.caption)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func copyActionItems() {
        exporter.copyActionItems(notes.actionItems)
        showCopiedFeedback(true)
    }

    private func copyAsMarkdown() {
        exporter.copyToClipboard(notes.markdown, format: .markdown)
        showCopiedFeedback(true)
    }

    private func copyAsPlainText() {
        exporter.copyToClipboard(notes.plainText, format: .plainText)
        showCopiedFeedback(true)
    }

    private func saveAsMarkdown() {
        exporter.saveMarkdownNotes(notes) { result in
            switch result {
            case .success:
                Logger.log("Notes saved successfully")
            case .failure(let error):
                Logger.log("Failed to save notes: \(error)", level: .error)
            }
        }
    }

    private func saveAsText() {
        let filename = "meeting-notes-\(notes.title).txt"
        exporter.saveToFile(notes.plainText, filename: filename, format: .plainText) { _ in }
    }

    private func openInMail(_ email: MeetingExporter.EmailDraft) {
        exporter.openInMail(email)
    }

    private func copyEmail(_ email: MeetingExporter.EmailDraft) {
        exporter.copyToClipboard(email.body, format: .plainText)
        showCopiedFeedback(true)
    }

    private func showCopiedFeedback(_ show: Bool) {
        withAnimation {
            showCopiedFeedback = show
        }
        if show {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showCopiedFeedback = false
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct NotesSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.headline)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct StatBadge: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct ActionItemRow: View {
    let item: MeetingExporter.ExportedActionItem
    @State private var isCompleted = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: { isCompleted.toggle() }) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.description)
                    .strikethrough(isCompleted)
                    .foregroundColor(isCompleted ? .secondary : .primary)

                HStack(spacing: 12) {
                    if let owner = item.owner {
                        Label(owner, systemImage: "person")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }

                    priorityBadge
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var priorityBadge: some View {
        Text(item.priority.rawValue)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(priorityColor.opacity(0.2))
            .foregroundColor(priorityColor)
            .cornerRadius(4)
    }

    private var priorityColor: Color {
        switch item.priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .gray
        }
    }
}

