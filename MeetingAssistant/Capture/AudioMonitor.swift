import Foundation
import AVFoundation
import ScreenCaptureKit
import Accelerate

// MARK: - Audio Monitor

@available(macOS 13.0, *)
final class AudioMonitor: NSObject, @unchecked Sendable {
    static let shared = AudioMonitor()

    // Configuration
    var transcriptionMode: TranscriptionMode = .whisperAPI
    var chunkDuration: TimeInterval = 5.0  // Seconds per chunk
    var silenceThreshold: Float = 0.01     // RMS threshold for silence detection

    // State
    private(set) var isMonitoring = false
    private(set) var hasPermission = false

    // Audio capture
    private var stream: SCStream?
    private var streamOutput: AudioCaptureOutput?

    // Audio buffering
    private var audioBuffer: [Float] = []
    private var sampleRate: Double = 48000
    private let bufferLock = NSLock()
    private var lastTranscriptionTime = Date()

    // Transcription
    private var transcriptionTask: Task<Void, Never>?
    private let whisperClient = WhisperAPIClient()

    // Callbacks
    var onTranscription: ((String) -> Void)?
    var onPartialTranscription: ((String) -> Void)?
    var onError: ((AudioMonitorError) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - Permission Handling

    func checkPermission() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            hasPermission = !content.displays.isEmpty
            return hasPermission
        } catch {
            hasPermission = false
            return false
        }
    }

    func requestPermission() async -> Bool {
        let hasAccess = await checkPermission()
        if !hasAccess {
            await MainActor.run {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        return hasAccess
    }

    // MARK: - Start/Stop

    func start() async throws {
        guard !isMonitoring else { return }

        // Check permission
        var hasAccess = await checkPermission()
        if !hasAccess {
            hasAccess = await requestPermission()
            if !hasAccess {
                throw AudioMonitorError.permissionDenied
            }
        }

        // Get display for audio capture (ScreenCaptureKit requires a display filter)
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        guard let display = content.displays.first else {
            throw AudioMonitorError.noAudioSource
        }

        // Configure for audio-only capture
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()

        // Minimal video (required but we ignore it)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 FPS

        // Audio configuration
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1  // Mono for transcription

        // Create output handler
        streamOutput = AudioCaptureOutput { [weak self] samples, format in
            self?.handleAudioSamples(samples, format: format)
        }

        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        guard let stream = stream, let output = streamOutput else {
            throw AudioMonitorError.captureSetupFailed
        }

        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()

        isMonitoring = true
        audioBuffer.removeAll()
        lastTranscriptionTime = Date()

        // Start transcription loop
        startTranscriptionLoop()

        print("Audio monitoring started (system audio)")
    }

    func stop() async {
        guard isMonitoring else { return }

        transcriptionTask?.cancel()
        transcriptionTask = nil

        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                print("Error stopping audio stream: \(error)")
            }
        }

        // Transcribe remaining buffer
        await transcribeBuffer(final: true)

        stream = nil
        streamOutput = nil
        isMonitoring = false
        audioBuffer.removeAll()

        print("Audio monitoring stopped")
    }

    // MARK: - Audio Processing

    private func handleAudioSamples(_ samples: [Float], format: AVAudioFormat) {
        bufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        bufferLock.unlock()

        // Calculate and report audio level
        let rms = calculateRMS(samples)
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(rms)
        }
    }

    private func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }

    // MARK: - Transcription Loop

    private func startTranscriptionLoop() {
        transcriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.isMonitoring else { break }

                let timeSinceLastTranscription = Date().timeIntervalSince(self.lastTranscriptionTime)

                if timeSinceLastTranscription >= self.chunkDuration {
                    await self.transcribeBuffer(final: false)
                }

                try? await Task.sleep(nanoseconds: 500_000_000)  // Check every 0.5s
            }
        }
    }

    private func transcribeBuffer(final: Bool) async {
        bufferLock.lock()
        let samples = audioBuffer
        audioBuffer.removeAll()
        bufferLock.unlock()

        guard !samples.isEmpty else { return }

        // Check if audio contains speech (not just silence)
        let rms = calculateRMS(samples)
        guard rms > silenceThreshold else {
            lastTranscriptionTime = Date()
            return
        }

        // Convert to audio data
        let audioData = samplesToWAV(samples, sampleRate: sampleRate)

        do {
            let transcription: String

            switch transcriptionMode {
            case .whisperAPI:
                transcription = try await whisperClient.transcribe(audioData: audioData)
            case .local:
                // Placeholder for local Whisper implementation
                transcription = "[Local transcription not yet implemented]"
            }

            if !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await MainActor.run { [weak self] in
                    self?.onTranscription?(transcription)
                }
            }

            lastTranscriptionTime = Date()

        } catch {
            await MainActor.run { [weak self] in
                self?.onError?(.transcriptionFailed(error))
            }
        }
    }

    // MARK: - Audio Format Conversion

    private func samplesToWAV(_ samples: [Float], sampleRate: Double) -> Data {
        // Convert Float samples to Int16 PCM
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        // Create WAV header
        var data = Data()

        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(int16Samples.count * 2)
        let fileSize = 36 + dataSize

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        // Audio data
        for sample in int16Samples {
            data.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
        }

        return data
    }
}

// MARK: - Audio Capture Output

@available(macOS 13.0, *)
private class AudioCaptureOutput: NSObject, SCStreamOutput {
    private let handler: ([Float], AVAudioFormat) -> Void

    init(handler: @escaping ([Float], AVAudioFormat) -> Void) {
        self.handler = handler
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }

        // Get audio buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else { return }

        // Convert based on format
        let samples: [Float]

        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Already float
            let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: length / 4)
            samples = Array(UnsafeBufferPointer(start: floatPointer, count: length / 4))
        } else {
            // Int16 PCM - convert to float
            let int16Pointer = UnsafeRawPointer(data).bindMemory(to: Int16.self, capacity: length / 2)
            let int16Buffer = UnsafeBufferPointer(start: int16Pointer, count: length / 2)
            samples = int16Buffer.map { Float($0) / Float(Int16.max) }
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: false
        )!

        handler(samples, format)
    }
}

// MARK: - Transcription Mode

enum TranscriptionMode {
    case whisperAPI   // OpenAI Whisper API (fast, requires API key)
    case local        // Local Whisper model (private, slower)
}

// MARK: - Errors

enum AudioMonitorError: Error, LocalizedError {
    case permissionDenied
    case noAudioSource
    case captureSetupFailed
    case transcriptionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission required for system audio capture."
        case .noAudioSource:
            return "No audio source available."
        case .captureSetupFailed:
            return "Failed to set up audio capture."
        case .transcriptionFailed(let error):
            return "Transcription failed: \(error.localizedDescription)"
        }
    }
}
