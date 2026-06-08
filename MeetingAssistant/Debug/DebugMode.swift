import Foundation
import Combine

// MARK: - Debug Mode Manager

final class DebugMode: ObservableObject {
    static let shared = DebugMode()

    // MARK: - State

    @Published private(set) var isEnabled = false
    @Published private(set) var isSimulating = false
    @Published private(set) var currentScenario: DebugScenario?
    @Published private(set) var simulationProgress: Double = 0
    @Published private(set) var currentTranscriptLine: Int = 0

    // MARK: - Stats

    @Published private(set) var stats = DebugStats()

    // MARK: - Logging

    @Published private(set) var logs: [DebugLogEntry] = []
    private let maxLogs = 500

    // MARK: - Simulation

    private var simulationTask: Task<Void, Never>?
    private var transcriptLines: [String] = []
    private var screenStates: [String] = []

    // MARK: - Callbacks

    var onTranscription: ((String) -> Void)?
    var onScreenUpdate: ((String) -> Void)?
    var onSimulationComplete: (() -> Void)?

    // MARK: - Configuration

    var transcriptionDelay: TimeInterval = 2.0  // Seconds between transcript lines
    var screenUpdateDelay: TimeInterval = 10.0  // Seconds between screen updates

    private init() {}

    // MARK: - Enable/Disable

    func enable() {
        isEnabled = true
        stats = DebugStats()
        log("Debug mode enabled", level: .info)
    }

    func disable() {
        stopSimulation()
        isEnabled = false
        log("Debug mode disabled", level: .info)
    }

    func toggle() {
        if isEnabled {
            disable()
        } else {
            enable()
        }
    }

    // MARK: - Simulation Control

    func startSimulation(scenario: DebugScenario) {
        guard isEnabled else {
            log("Cannot start simulation - debug mode not enabled", level: .warning)
            return
        }

        stopSimulation()

        currentScenario = scenario
        transcriptLines = scenario.transcript.components(separatedBy: "\n").filter { !$0.isEmpty }
        screenStates = scenario.screenStates
        currentTranscriptLine = 0
        simulationProgress = 0

        log("Starting simulation: \(scenario.name)", level: .info)
        isSimulating = true

        simulationTask = Task { [weak self] in
            await self?.runSimulation()
        }
    }

    func stopSimulation() {
        simulationTask?.cancel()
        simulationTask = nil
        isSimulating = false
        simulationProgress = 0
        currentTranscriptLine = 0
        log("Simulation stopped", level: .info)
    }

    func pauseSimulation() {
        // TODO: Implement pause/resume
    }

    private func runSimulation() async {
        let totalLines = transcriptLines.count
        var screenIndex = 0
        let screenUpdateInterval = max(1, totalLines / max(1, screenStates.count))

        for (index, line) in transcriptLines.enumerated() {
            guard !Task.isCancelled else { break }

            currentTranscriptLine = index + 1
            simulationProgress = Double(index + 1) / Double(totalLines)

            // Send transcription
            await MainActor.run {
                onTranscription?(line)
                stats.transcriptionCount += 1
            }
            log("Transcription: \(line.prefix(50))...", level: .debug)

            // Update screen periodically
            if index % screenUpdateInterval == 0 && screenIndex < screenStates.count {
                let screenContent = screenStates[screenIndex]
                await MainActor.run {
                    onScreenUpdate?(screenContent)
                    stats.screenCaptureCount += 1
                }
                screenIndex += 1
                log("Screen update: \(screenContent.prefix(30))...", level: .debug)
            }

            // Wait before next line
            try? await Task.sleep(nanoseconds: UInt64(transcriptionDelay * 1_000_000_000))
        }

        await MainActor.run {
            isSimulating = false
            simulationProgress = 1.0
            onSimulationComplete?()
        }
        log("Simulation complete", level: .info)
    }

    // MARK: - Mock API

    func mockClaudeResponse(for prompt: String) -> String {
        stats.apiCallCount += 1
        let startTime = Date()

        // Simulate API delay
        Thread.sleep(forTimeInterval: 0.3)

        let response: String
        if prompt.lowercased().contains("prediction") {
            response = mockPredictionResponse()
        } else if prompt.lowercased().contains("summary") {
            response = mockSummaryResponse()
        } else if prompt.lowercased().contains("action") {
            response = mockActionItemsResponse()
        } else if prompt.lowercased().contains("email") {
            response = mockEmailResponse()
        } else {
            response = mockGenericResponse()
        }

        let elapsed = Date().timeIntervalSince(startTime)
        stats.lastAPIResponseTime = elapsed
        stats.totalAPITime += elapsed
        stats.estimatedTokensUsed += estimateTokens(prompt + response)

        log("API call completed in \(String(format: "%.2f", elapsed * 1000))ms", level: .debug)

        return response
    }

    private func mockPredictionResponse() -> String {
        """
        {
            "predictions": [
                {"question": "When is the deadline for this feature?", "answer": "The deadline is end of this sprint, which is Friday.", "confidence": 8},
                {"question": "Who is responsible for the backend changes?", "answer": "Based on the discussion, Alex will handle the backend implementation.", "confidence": 7},
                {"question": "What's the priority of this task?", "answer": "This is marked as high priority for the current sprint.", "confidence": 9}
            ]
        }
        """
    }

    private func mockSummaryResponse() -> String {
        """
        The team discussed the upcoming feature release and identified key blockers.
        Main focus areas include API optimization and UI improvements.
        Several action items were assigned with clear owners and deadlines.
        """
    }

    private func mockActionItemsResponse() -> String {
        """
        [
            "Complete API documentation by Friday - @Alex",
            "Review pull request #234 - @Sarah",
            "Update project timeline in Jira - @Mike",
            "Schedule follow-up meeting for next week - @Team Lead"
        ]
        """
    }

    private func mockEmailResponse() -> String {
        """
        {
            "subject": "Follow-up: Team Meeting - Sprint Planning",
            "body": "Hi Team,\\n\\nThank you for attending today's meeting. Here's a quick summary:\\n\\nKey Points:\\n- Feature release scheduled for Friday\\n- API optimization is high priority\\n- All blockers have been identified and assigned\\n\\nAction Items:\\n- Alex: Complete API docs by Friday\\n- Sarah: Review PR #234\\n- Mike: Update timeline\\n\\nPlease let me know if you have any questions.\\n\\nBest regards"
        }
        """
    }

    private func mockGenericResponse() -> String {
        "Based on the meeting context, the team is making good progress on the current sprint goals. Key topics discussed include feature development, timeline adjustments, and resource allocation."
    }

    private func estimateTokens(_ text: String) -> Int {
        return Int(Double(text.count) * 0.25)
    }

    // MARK: - Logging

    func log(_ message: String, level: DebugLogLevel = .info, file: String = #file, function: String = #function, line: Int = #line) {
        let entry = DebugLogEntry(
            timestamp: Date(),
            level: level,
            message: message,
            file: (file as NSString).lastPathComponent,
            function: function,
            line: line
        )

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logs.append(entry)

            // Trim old logs
            if self.logs.count > self.maxLogs {
                self.logs.removeFirst(self.logs.count - self.maxLogs)
            }
        }

        // Also print to console in debug mode
        #if DEBUG
        print("[\(level.rawValue.uppercased())] \(message)")
        #endif
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Stats Reset

    func resetStats() {
        stats = DebugStats()
    }
}

// MARK: - Debug Stats

struct DebugStats {
    var transcriptionCount: Int = 0
    var screenCaptureCount: Int = 0
    var predictionCount: Int = 0
    var apiCallCount: Int = 0
    var lastAPIResponseTime: TimeInterval = 0
    var totalAPITime: TimeInterval = 0
    var estimatedTokensUsed: Int = 0

    var averageAPIResponseTime: TimeInterval {
        guard apiCallCount > 0 else { return 0 }
        return totalAPITime / Double(apiCallCount)
    }
}

// MARK: - Debug Log Entry

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: DebugLogLevel
    let message: String
    let file: String
    let function: String
    let line: Int

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

enum DebugLogLevel: String {
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"

    var color: String {
        switch self {
        case .debug: return "gray"
        case .info: return "blue"
        case .warning: return "orange"
        case .error: return "red"
        }
    }
}

// MARK: - Debug Scenarios

struct DebugScenario: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let transcript: String
    let screenStates: [String]
    let expectedDuration: TimeInterval  // Estimated real meeting duration

    static let techTeamMeeting = DebugScenario(
        name: "Tech Team Standup",
        description: "Daily standup with development team discussing sprint progress",
        transcript: """
        [Sarah]: Good morning everyone, let's start the standup.
        [Alex]: Morning! I finished the API refactoring yesterday.
        [Sarah]: Great progress Alex. Any blockers?
        [Alex]: Yes, I'm waiting on the database schema review from Mike.
        [Mike]: Sorry about that, I'll review it today by noon.
        [Sarah]: Perfect. What are you working on today Alex?
        [Alex]: I'll start on the authentication module once the schema is approved.
        [Sarah]: Sounds good. Mike, what's your update?
        [Mike]: I deployed the caching layer to staging yesterday. Running performance tests now.
        [Sarah]: How are the results looking?
        [Mike]: So far we're seeing a 40% improvement in response times.
        [Sarah]: Excellent! Any issues with the deployment?
        [Mike]: Minor config issue but I fixed it this morning. All green now.
        [Sarah]: Great. What's the plan for today?
        [Mike]: Finish the performance analysis and write up the documentation.
        [Sarah]: Perfect. Lisa, you're up.
        [Lisa]: I'm still working on the UI redesign for the dashboard.
        [Sarah]: What's the timeline looking like?
        [Lisa]: I should have the mockups ready by tomorrow.
        [Sarah]: Any dependencies or blockers?
        [Lisa]: I need the updated brand colors from the design team.
        [Sarah]: I'll ping them after this call. Anything else?
        [Lisa]: No, that's it from me.
        [Sarah]: Alright, let's talk about the sprint deadline.
        [Alex]: It's Friday, right? Are we on track?
        [Sarah]: Yes, Friday. Based on our progress, I think we're in good shape.
        [Mike]: The caching feature will be ready by Wednesday.
        [Sarah]: Great. Any concerns about the deadline?
        [Lisa]: The UI work might need a few more days.
        [Sarah]: That's fine, we can push that to the next sprint if needed.
        [Sarah]: Alright, let's wrap up. Good progress everyone!
        """,
        screenStates: [
            "JIRA Board\n\nSprint 23\nIn Progress: 5\nDone: 8\nBlocked: 1\n\nAPI Refactoring - Alex - In Progress\nCaching Layer - Mike - Testing\nUI Redesign - Lisa - In Progress",
            "Slack Channel: #dev-team\n\nAlex: Schema looks good, approved!\nMike: Thanks, deploying now\nSarah: Great teamwork everyone",
            "Performance Dashboard\n\nAPI Response Time: 120ms → 72ms\nCache Hit Rate: 87%\nError Rate: 0.1%\nActive Users: 1,234"
        ],
        expectedDuration: 900  // 15 minutes
    )

    static let salesCall = DebugScenario(
        name: "Sales Discovery Call",
        description: "Initial sales call with a potential enterprise customer",
        transcript: """
        [Sales Rep]: Thanks for joining the call today. How are you doing?
        [Customer]: Good, thanks. Excited to learn more about your product.
        [Sales Rep]: Great! Before we dive in, can you tell me about your current workflow?
        [Customer]: Sure. We're using spreadsheets to track everything right now.
        [Sales Rep]: How many people are on your team?
        [Customer]: About 50 people across three departments.
        [Sales Rep]: That's a good size team. What challenges are you facing?
        [Customer]: The main issue is data silos. Each department has their own spreadsheets.
        [Sales Rep]: That's a common problem. How does that impact your operations?
        [Customer]: It takes hours to compile reports at the end of each month.
        [Sales Rep]: I understand. What would the ideal solution look like for you?
        [Customer]: A centralized system where everyone can collaborate in real-time.
        [Sales Rep]: Perfect, that's exactly what our platform provides.
        [Customer]: What about security? We handle sensitive data.
        [Sales Rep]: We're SOC 2 Type II certified and offer enterprise-grade security.
        [Customer]: That's important. What about integrations?
        [Sales Rep]: We integrate with over 100 tools including Salesforce and Slack.
        [Customer]: Do you have a Jira integration?
        [Sales Rep]: Yes, we have a native Jira integration with two-way sync.
        [Customer]: That's great. What about pricing?
        [Sales Rep]: For a team of 50, you'd be looking at the Business tier.
        [Customer]: What does that include?
        [Sales Rep]: Unlimited users, advanced analytics, and priority support.
        [Customer]: What's the implementation timeline?
        [Sales Rep]: Typically 2-4 weeks depending on complexity.
        [Customer]: Can we do a pilot program first?
        [Sales Rep]: Absolutely! We offer a 30-day proof of concept.
        [Customer]: That sounds reasonable. What are the next steps?
        [Sales Rep]: I'll send over a proposal and we can schedule a technical demo.
        [Customer]: Perfect. When can you send that?
        [Sales Rep]: I'll have it to you by end of day tomorrow.
        """,
        screenStates: [
            "Customer Profile\n\nCompany: Acme Corp\nSize: 50 employees\nIndustry: Manufacturing\nCurrent Solution: Spreadsheets\nBudget: $50K/year",
            "Product Demo - Dashboard\n\nReal-time Analytics\nTeam Collaboration\nCustom Reports\n100+ Integrations",
            "Pricing Tiers\n\nStarter: $10/user/mo\nBusiness: $25/user/mo\nEnterprise: Custom\n\nAcme Quote: $15,000/year"
        ],
        expectedDuration: 1800  // 30 minutes
    )

    static let designReview = DebugScenario(
        name: "Design Review Meeting",
        description: "UX team reviewing new feature designs and gathering feedback",
        transcript: """
        [Designer]: Welcome everyone to the design review for the new onboarding flow.
        [PM]: Thanks for putting this together. Excited to see the updates.
        [Designer]: Let me share my screen and walk through the mockups.
        [PM]: Great, I can see it now.
        [Designer]: So the first screen is the welcome page with the new illustration.
        [Dev]: I like the cleaner look. The old one felt cluttered.
        [Designer]: Thanks! We focused on reducing cognitive load.
        [PM]: What about mobile responsiveness?
        [Designer]: All designs are mobile-first. I'll show the mobile versions next.
        [Dev]: How does the animation work on the progress indicator?
        [Designer]: It's a simple CSS transition, nothing too complex.
        [PM]: Can we A/B test the two header variations?
        [Designer]: Yes, I've prepared both versions for that.
        [Dev]: What's the accessibility score on this design?
        [Designer]: We're at WCAG AA compliance. Working on AAA for the forms.
        [PM]: The color contrast looks better than the previous version.
        [Designer]: We increased it based on user feedback.
        [PM]: What about the empty states?
        [Designer]: Good point. Let me show those next.
        [Designer]: Here's the empty state for new users with no data.
        [Dev]: That's much clearer. The old one was confusing.
        [PM]: Can we add a sample data option for new users?
        [Designer]: That's a great idea. I'll add that to the next iteration.
        [Dev]: What's the font size on the secondary text?
        [Designer]: 14px with 1.5 line height for readability.
        [PM]: Overall, I think this is a huge improvement.
        [Dev]: Agreed. When can we start implementation?
        [Designer]: I'll finalize the specs by Monday.
        [PM]: Perfect. Let's target next sprint for development.
        """,
        screenStates: [
            "Figma - Onboarding Flow v2\n\nScreen 1: Welcome\nScreen 2: Account Setup\nScreen 3: Team Invite\nScreen 4: Tutorial\n\nStatus: In Review",
            "Design Specs\n\nPrimary Color: #2563EB\nFont: Inter\nSpacing: 8px grid\nBorder Radius: 8px\n\nAccessibility: WCAG AA",
            "User Flow Diagram\n\nSignup → Welcome → Setup → Invite → Dashboard\n\nDropoff Rate Target: <20%\nCompletion Rate: 85%"
        ],
        expectedDuration: 1200  // 20 minutes
    )

    static let allScenarios: [DebugScenario] = [
        techTeamMeeting,
        salesCall,
        designReview
    ]
}
