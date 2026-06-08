import Foundation
import Cocoa

final class MeetingService {
    private var isMonitoring = false
    private var timer: Timer?

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkForActiveMeetings()
        }

        print("Meeting monitoring started")
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        print("Meeting monitoring stopped")
    }

    private func checkForActiveMeetings() {
        // Check for running meeting apps (Zoom, Teams, Meet, etc.)
        let meetingApps = ["zoom.us", "Microsoft Teams", "Google Chrome", "Safari"]
        let runningApps = NSWorkspace.shared.runningApplications

        for app in runningApps {
            if let name = app.localizedName, meetingApps.contains(where: { name.contains($0) }) {
                print("Detected potential meeting app: \(name)")
            }
        }
    }
}
