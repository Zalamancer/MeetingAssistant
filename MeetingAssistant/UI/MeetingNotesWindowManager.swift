import SwiftUI
import AppKit

// MARK: - Meeting Notes Window Manager

final class MeetingNotesWindowManager {
    static let shared = MeetingNotesWindowManager()

    private var notesWindow: NSWindow?

    private init() {}

    // MARK: - Show Notes

    @MainActor
    func showMeetingNotes(
        _ notes: MeetingExporter.MeetingNotes,
        emailDraft: MeetingExporter.EmailDraft?
    ) {
        // Close existing window if open
        notesWindow?.close()

        let notesView = MeetingNotesView(notes: notes, emailDraft: emailDraft)
        let hostingController = NSHostingController(rootView: notesView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Meeting Notes - \(notes.title)"
        window.setContentSize(NSSize(width: 600, height: 500))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 400, height: 300)
        window.center()
        window.makeKeyAndOrderFront(nil)

        notesWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func showMeetingNotes(from result: MeetingExporter.ExportResult) {
        showMeetingNotes(result.meetingNotes, emailDraft: result.emailDraft)
    }

    // MARK: - Generate and Show

    @MainActor
    func generateAndShowNotes() async {
        let coordinator = MeetingAssistantCoordinator.shared

        do {
            let result = try await coordinator.generateMeetingNotes()
            showMeetingNotes(from: result)
        } catch {
            Logger.log("Failed to generate meeting notes: \(error)", level: .error)
            showErrorAlert(error)
        }
    }

    // MARK: - Quick Actions

    @MainActor
    func showAfterMeetingEnds(
        meeting: MeetingInfo,
        context: FullMeetingContext,
        predictions: [Prediction]
    ) async {
        do {
            let result = try await MeetingExporter.shared.generateExport(
                from: context,
                meetingInfo: meeting,
                predictions: predictions
            )
            showMeetingNotes(from: result)
        } catch {
            Logger.log("Failed to generate post-meeting notes: \(error)", level: .error)
        }
    }

    // MARK: - Close

    func closeNotesWindow() {
        notesWindow?.close()
        notesWindow = nil
    }

    // MARK: - Error Handling

    @MainActor
    private func showErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Failed to Generate Notes"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Coordinator Extension

extension MeetingAssistantCoordinator {
    @MainActor
    func showMeetingNotesWindow() async {
        await MeetingNotesWindowManager.shared.generateAndShowNotes()
    }
}
