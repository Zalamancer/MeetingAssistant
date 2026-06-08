import Foundation
import AppKit
import UserNotifications

// MARK: - Additional Coordinator Features

extension MeetingAssistantCoordinator {
    // MARK: - Meeting Detection

    /// Auto-detect and join meeting based on running apps
    func detectAndJoinMeeting() async throws {
        guard state == .idle else { return }

        let meetingApp = await screenMonitor.detectMeetingApp()

        if let app = meetingApp {
            Logger.log("Detected meeting app: \(app.rawValue)")

            try await startMeeting(
                title: "Meeting via \(app.rawValue)",
                participants: []
            )
        }
    }

    /// Monitor for meeting app launch
    func startMeetingAppMonitoring() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier else { return }

            let meetingBundleIds = ["us.zoom.xos", "com.microsoft.teams", "com.cisco.webexmeetingsapp"]

            if meetingBundleIds.contains(where: { bundleId.contains($0) }) {
                Task { @MainActor in
                    try? await self?.detectAndJoinMeeting()
                }
            }
        }
    }

    // MARK: - Notifications

    func sendNotification(title: String, body: String) {
        guard SettingsManager.shared.showNotifications else { return }
        guard Bundle.main.bundleIdentifier != nil else {
            // Running without proper bundle (e.g., swift run)
            Logger.log("Notification skipped - no bundle identifier", level: .debug)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else {
            // Running without proper bundle (e.g., swift run)
            Logger.log("Notification permission skipped - no bundle identifier", level: .debug)
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Logger.log("Notification permission error: \(error)", level: .error)
            }
        }
    }

    // MARK: - Follow-up Email Generation

    func generateFollowUpEmail() async throws -> String {
        guard let meeting = currentMeeting else {
            throw CoordinatorError.meetingNotActive
        }

        let fullContext = context.getFullContext()
        let actionItems = fullContext.actionItems.map { "• \($0.description)" }.joined(separator: "\n")
        let topics = fullContext.topics.joined(separator: ", ")

        let prompt = """
        Generate a professional follow-up email for this meeting.
        Include: summary, action items, and next steps.
        Keep it concise and actionable.

        Meeting: \(meeting.title)
        Participants: \(meeting.participants.joined(separator: ", "))
        Topics discussed: \(topics)
        Action items:
        \(actionItems)

        Generate the email:
        """

        return try await ClaudeAPIClient.shared.sendMessage(prompt, includeHistory: false)
    }

    // MARK: - Quick Actions

    func copyTopPredictionAnswer() {
        guard let topPrediction = activePredictions.first else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(topPrediction.answer, forType: .string)

        if SettingsManager.shared.playSoundOnPrediction {
            NSSound.beep()
        }

        Logger.log("Copied top prediction answer to clipboard")
    }

    func copyAllActionItems() async throws {
        let items = try await context.extractActionItemsWithAI()
        let text = items.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Statistics

    struct SessionStats {
        let duration: TimeInterval
        let transcriptionCount: Int
        let wordCount: Int
        let predictionCount: Int
        let questionsAnswered: Int
        let tokensUsed: Int
    }

    func getSessionStats() -> SessionStats {
        let fullContext = context.getFullContext()
        let wordCount = fullContext.transcriptions
            .map { $0.text.split(separator: " ").count }
            .reduce(0, +)

        let answerStats = answerGenerator.getStats()

        return SessionStats(
            duration: meetingDuration,
            transcriptionCount: fullContext.transcriptions.count,
            wordCount: wordCount,
            predictionCount: predictionEngine.getStats().totalGenerated,
            questionsAnswered: answerStats.totalAnswered,
            tokensUsed: fullContext.estimatedTokens
        )
    }

    // MARK: - Keyboard Shortcuts

    func setupGlobalShortcuts() {
        // These would integrate with the FloatingWindowManager hotkeys
        // Additional shortcuts could be added here
    }

    // MARK: - State Persistence

    func saveState() {
        guard let meeting = currentMeeting else { return }

        let stateData = CoordinatorState(
            meetingInfo: meeting,
            state: state,
            startTime: meetingStartTime
        )

        if let encoded = try? JSONEncoder().encode(stateData) {
            UserDefaults.standard.set(encoded, forKey: "coordinatorState")
        }
    }

    func restoreState() async {
        guard let data = UserDefaults.standard.data(forKey: "coordinatorState"),
              let stateData = try? JSONDecoder().decode(CoordinatorState.self, from: data) else {
            return
        }

        // Only restore if the meeting was recent (within 1 hour)
        if let startTime = stateData.startTime,
           Date().timeIntervalSince(startTime) < 3600 {
            Logger.log("Restoring previous meeting state")
            // Could prompt user to resume
        }

        UserDefaults.standard.removeObject(forKey: "coordinatorState")
    }

    // MARK: - Integration Helpers

    func getContextForExternalUse() -> [String: Any] {
        let fullContext = context.getFullContext()

        return [
            "title": currentMeeting?.title ?? "",
            "duration": meetingDuration,
            "participants": currentMeeting?.participants ?? [],
            "topics": fullContext.topics,
            "transcriptCount": fullContext.transcriptions.count,
            "predictions": activePredictions.map { [
                "question": $0.question,
                "answer": $0.answer,
                "confidence": $0.confidence
            ]},
            "tokensUsed": fullContext.estimatedTokens
        ]
    }
}

// MARK: - State Persistence Types

struct CoordinatorState: Codable {
    let meetingInfo: MeetingInfo
    let state: String
    let startTime: Date?

    init(meetingInfo: MeetingInfo, state: MeetingState, startTime: Date?) {
        self.meetingInfo = meetingInfo
        self.state = state.rawValue
        self.startTime = startTime
    }
}

// MARK: - Coordinator Event Types

enum CoordinatorEvent {
    case meetingStarted(MeetingInfo)
    case meetingEnded(MeetingSummary)
    case meetingPaused
    case meetingResumed
    case newTranscription(String)
    case newPredictions([Prediction])
    case error(CoordinatorError)
}

// MARK: - Meeting Templates

extension MeetingAssistantCoordinator {
    struct MeetingTemplate {
        let name: String
        let defaultTitle: String
        let systemPrompt: String
        let predictionFocus: [String]
    }

    static let templates: [MeetingTemplate] = [
        MeetingTemplate(
            name: "Stand-up",
            defaultTitle: "Daily Stand-up",
            systemPrompt: "This is a daily stand-up meeting. Focus on blockers, progress, and plans.",
            predictionFocus: ["blockers", "progress", "timeline"]
        ),
        MeetingTemplate(
            name: "Sprint Planning",
            defaultTitle: "Sprint Planning",
            systemPrompt: "This is a sprint planning meeting. Focus on story points, capacity, and commitments.",
            predictionFocus: ["estimation", "scope", "dependencies"]
        ),
        MeetingTemplate(
            name: "Retrospective",
            defaultTitle: "Sprint Retrospective",
            systemPrompt: "This is a retrospective meeting. Focus on what went well, what didn't, and improvements.",
            predictionFocus: ["improvements", "issues", "action items"]
        ),
        MeetingTemplate(
            name: "1:1",
            defaultTitle: "One-on-One",
            systemPrompt: "This is a 1:1 meeting. Focus on career growth, feedback, and support needs.",
            predictionFocus: ["feedback", "goals", "support"]
        ),
        MeetingTemplate(
            name: "Client",
            defaultTitle: "Client Meeting",
            systemPrompt: "This is a client meeting. Focus on requirements, timelines, and deliverables.",
            predictionFocus: ["requirements", "timeline", "budget"]
        )
    ]

    func startMeetingWithTemplate(_ template: MeetingTemplate) async throws {
        // Set custom system prompt
        ClaudeAPIClient.shared.setSystemPrompt("""
            You are a meeting assistant. \(template.systemPrompt)
            Focus predictions on: \(template.predictionFocus.joined(separator: ", ")).
            Be concise and actionable.
            """)

        try await startMeeting(title: template.defaultTitle)
    }
}
