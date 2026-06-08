import Foundation
import AVFoundation

final class AudioCaptureService {
    private var isCapturing = false

    // Check and request microphone permission
    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func startCapture() async throws {
        guard await requestPermission() else {
            throw CaptureError.permissionDenied
        }

        guard !isCapturing else { return }
        isCapturing = true

        // Audio capture implementation would go here
        // Using AVAudioEngine or ScreenCaptureKit for system audio
        print("Audio capture started")
    }

    func stopCapture() {
        isCapturing = false
        print("Audio capture stopped")
    }
}

enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case captureFailure

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone permission denied"
        case .captureFailure: return "Failed to capture audio"
        }
    }
}
