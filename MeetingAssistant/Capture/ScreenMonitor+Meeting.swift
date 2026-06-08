import Foundation
import AppKit

// MARK: - Meeting-Specific Extensions

@available(macOS 13.0, *)
extension ScreenMonitor {
    /// Start monitoring with meeting-optimized settings
    func startMeetingCapture(
        onText: @escaping (String) -> Void,
        onAnalysis: ((ScreenAnalysis) -> Void)? = nil
    ) async throws {
        // Configure for meeting use
        captureInterval = 2.0  // Every 2 seconds to reduce CPU
        enableOCR = true
        enableAIAnalysis = onAnalysis != nil

        // Set callbacks
        onTextExtracted = onText
        onScreenAnalysis = onAnalysis

        try await start()
    }

    /// Get a summary of recently captured content
    func summarizeRecentCaptures(_ captures: [String]) async throws -> String {
        guard !captures.isEmpty else {
            return "No screen content captured yet."
        }

        let combinedText = captures.suffix(5).joined(separator: "\n---\n")

        let prompt = """
        Summarize what was shown on screen during this meeting segment.
        Focus on: key topics, decisions, or action items visible.
        Keep it brief (2-3 sentences).

        Screen content:
        \(combinedText.prefix(3000))
        """

        return try await ClaudeAPIClient.shared.predict(prompt)
    }
}

// MARK: - Screen Content Buffer

@available(macOS 13.0, *)
final class ScreenContentBuffer {
    private var textBuffer: [TimestampedText] = []
    private let maxBufferSize = 50
    private let deduplicationThreshold = 0.8  // 80% similarity = duplicate

    struct TimestampedText {
        let text: String
        let timestamp: Date
        let contentType: ContentType
    }

    func add(_ text: String, type: ContentType = .unknown) {
        // Skip if too similar to last entry (avoid duplicates)
        if let last = textBuffer.last {
            let similarity = calculateSimilarity(text, last.text)
            if similarity > deduplicationThreshold {
                return
            }
        }

        let entry = TimestampedText(
            text: text,
            timestamp: Date(),
            contentType: type
        )

        textBuffer.append(entry)

        // Trim buffer if too large
        if textBuffer.count > maxBufferSize {
            textBuffer.removeFirst(10)
        }
    }

    func getRecent(count: Int = 10) -> [TimestampedText] {
        Array(textBuffer.suffix(count))
    }

    func getAll() -> [TimestampedText] {
        textBuffer
    }

    func clear() {
        textBuffer.removeAll()
    }

    func getTextSince(_ date: Date) -> [TimestampedText] {
        textBuffer.filter { $0.timestamp >= date }
    }

    // Simple similarity calculation (Jaccard index on words)
    private func calculateSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.lowercased().split(separator: " "))
        let words2 = Set(text2.lowercased().split(separator: " "))

        guard !words1.isEmpty || !words2.isEmpty else { return 1.0 }

        let intersection = words1.intersection(words2).count
        let union = words1.union(words2).count

        return Double(intersection) / Double(union)
    }
}

// MARK: - Window Detection (Optional Enhancement)

@available(macOS 13.0, *)
extension ScreenMonitor {
    /// Detect if a meeting app window is active
    func detectMeetingApp() async -> MeetingApp? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let bundleId = frontApp.bundleIdentifier ?? ""
        let appName = frontApp.localizedName ?? ""

        switch bundleId {
        case let id where id.contains("zoom"):
            return .zoom
        case let id where id.contains("teams"):
            return .teams
        case let id where id.contains("webex"):
            return .webex
        case let id where id.contains("slack"):
            return .slack
        case "com.google.Chrome", "com.apple.Safari":
            // Could be Google Meet - would need window title check
            if appName.contains("Meet") {
                return .googleMeet
            }
            return nil
        default:
            return nil
        }
    }
}

enum MeetingApp: String {
    case zoom = "Zoom"
    case teams = "Microsoft Teams"
    case googleMeet = "Google Meet"
    case webex = "Webex"
    case slack = "Slack"

    var icon: String {
        switch self {
        case .zoom: return "video.fill"
        case .teams: return "person.3.fill"
        case .googleMeet: return "video.circle.fill"
        case .webex: return "network"
        case .slack: return "number.square.fill"
        }
    }
}
