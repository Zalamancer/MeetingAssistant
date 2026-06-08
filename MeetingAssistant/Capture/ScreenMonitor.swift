import Foundation
import ScreenCaptureKit
import CoreGraphics
import Vision
import AppKit

// MARK: - Screen Monitor

@available(macOS 13.0, *)
final class ScreenMonitor: NSObject, @unchecked Sendable {
    static let shared = ScreenMonitor()

    // Configuration
    var captureInterval: TimeInterval = 1.0  // 1 FPS default
    var enableOCR: Bool = true
    var enableAIAnalysis: Bool = false

    // State
    private(set) var isMonitoring = false
    private(set) var hasPermission = false

    // Capture components
    private var stream: SCStream?
    private var streamOutput: ScreenCaptureOutput?
    private var captureTimer: Timer?
    private var currentDisplay: SCDisplay?
    private var lastCapturedImage: CGImage?

    // Callbacks
    var onTextExtracted: ((String) -> Void)?
    var onScreenAnalysis: ((ScreenAnalysis) -> Void)?
    var onError: ((ScreenMonitorError) -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - Permission Handling

    func checkPermission() async -> Bool {
        do {
            // Attempting to get shareable content checks permission
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            hasPermission = !content.displays.isEmpty
            return hasPermission
        } catch {
            hasPermission = false
            return false
        }
    }

    func requestPermission() async -> Bool {
        // ScreenCaptureKit automatically prompts for permission
        // when you try to access shareable content
        let hasAccess = await checkPermission()

        if !hasAccess {
            // Open System Preferences to Screen Recording
            await MainActor.run {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        return hasAccess
    }

    // MARK: - Start/Stop Monitoring

    func start() async throws {
        guard !isMonitoring else { return }

        // Check permission first
        var hasAccess = await checkPermission()
        if !hasAccess {
            hasAccess = await requestPermission()
            if !hasAccess {
                throw ScreenMonitorError.permissionDenied
            }
        }

        // Get available displays
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        guard let display = content.displays.first else {
            throw ScreenMonitorError.noDisplayFound
        }

        currentDisplay = display

        // Configure stream
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()

        // Optimize for text capture (lower resolution is fine for OCR)
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(captureInterval))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        // Create stream
        streamOutput = ScreenCaptureOutput { [weak self] image in
            self?.handleCapturedFrame(image)
        }

        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        guard let stream = stream, let output = streamOutput else {
            throw ScreenMonitorError.streamCreationFailed
        }

        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()

        isMonitoring = true
        print("Screen monitoring started")
    }

    func stop() async {
        guard isMonitoring else { return }

        captureTimer?.invalidate()
        captureTimer = nil

        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                print("Error stopping stream: \(error)")
            }
        }

        stream = nil
        streamOutput = nil
        isMonitoring = false
        print("Screen monitoring stopped")
    }

    // MARK: - Frame Processing

    private func handleCapturedFrame(_ image: CGImage) {
        lastCapturedImage = image

        if enableOCR {
            Task {
                await processFrameForOCR(image)
            }
        }
    }

    private func processFrameForOCR(_ image: CGImage) async {
        do {
            let text = try await extractText(from: image)

            if !text.isEmpty {
                await MainActor.run {
                    onTextExtracted?(text)
                }

                // Optionally analyze with Claude
                if enableAIAnalysis {
                    await analyzeScreenContent(text: text, image: image)
                }
            }
        } catch {
            await MainActor.run {
                onError?(.ocrFailed(error))
            }
        }
    }

    // MARK: - OCR with Vision Framework

    private func extractText(from image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let text = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")

                continuation.resume(returning: text)
            }

            // Configure for accuracy vs speed
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - AI Analysis (Optional)

    private func analyzeScreenContent(text: String, image: CGImage) async {
        // Use Claude to understand what's on screen
        let prompt = """
        Based on this text extracted from a screen during a meeting, briefly describe:
        1. What type of content is being shown (slides, document, code, chat, etc.)
        2. Key information visible

        Keep response under 50 words.

        Extracted text:
        \(text.prefix(2000))
        """

        do {
            let analysis = try await ClaudeAPIClient.shared.predict(prompt)
            let screenAnalysis = ScreenAnalysis(
                extractedText: text,
                contentType: detectContentType(from: text),
                aiDescription: analysis,
                timestamp: Date()
            )

            await MainActor.run {
                onScreenAnalysis?(screenAnalysis)
            }
        } catch {
            print("AI analysis failed: \(error)")
        }
    }

    private func detectContentType(from text: String) -> ContentType {
        let lowercased = text.lowercased()

        if lowercased.contains("func ") || lowercased.contains("class ") ||
           lowercased.contains("import ") || lowercased.contains("def ") {
            return .code
        } else if lowercased.contains("slide") || text.contains("•") ||
                  text.split(separator: "\n").count < 10 {
            return .slides
        } else if lowercased.contains("@") && lowercased.contains(":") {
            return .chat
        } else {
            return .document
        }
    }

    // MARK: - Manual Capture

    @available(macOS 14.0, *)
    func captureNow() async throws -> ScreenCapture {
        guard hasPermission else {
            throw ScreenMonitorError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        guard let display = content.displays.first else {
            throw ScreenMonitorError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        let text = try await extractText(from: image)

        return ScreenCapture(
            image: image,
            extractedText: text,
            timestamp: Date()
        )
    }
}

// MARK: - Stream Output Handler

@available(macOS 13.0, *)
private class ScreenCaptureOutput: NSObject, SCStreamOutput {
    private let handler: (CGImage) -> Void
    private var frameCount = 0
    private let processEveryNthFrame = 1  // Process every frame at 1 FPS

    init(handler: @escaping (CGImage) -> Void) {
        self.handler = handler
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        frameCount += 1
        guard frameCount % processEveryNthFrame == 0 else { return }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        handler(cgImage)
    }
}

// MARK: - Data Types

struct ScreenCapture {
    let image: CGImage
    let extractedText: String
    let timestamp: Date
}

struct ScreenAnalysis {
    let extractedText: String
    let contentType: ContentType
    let aiDescription: String
    let timestamp: Date
}

enum ContentType: String {
    case slides = "Presentation/Slides"
    case document = "Document"
    case code = "Code"
    case chat = "Chat/Messages"
    case browser = "Web Browser"
    case unknown = "Unknown"
}

// MARK: - Errors

enum ScreenMonitorError: Error, LocalizedError {
    case permissionDenied
    case noDisplayFound
    case streamCreationFailed
    case captureFailed
    case ocrFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission denied. Please enable in System Settings > Privacy & Security > Screen Recording."
        case .noDisplayFound:
            return "No display found to capture."
        case .streamCreationFailed:
            return "Failed to create screen capture stream."
        case .captureFailed:
            return "Failed to capture screen."
        case .ocrFailed(let error):
            return "OCR failed: \(error.localizedDescription)"
        }
    }
}
