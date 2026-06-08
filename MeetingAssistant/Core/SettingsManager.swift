import Foundation
import SwiftUI

// MARK: - Settings Manager

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - API Settings

    @Published var hasClaudeAPIKey: Bool {
        didSet { defaults.set(hasClaudeAPIKey, forKey: Keys.hasClaudeAPIKey) }
    }

    @Published var hasOpenAIAPIKey: Bool {
        didSet { defaults.set(hasOpenAIAPIKey, forKey: Keys.hasOpenAIAPIKey) }
    }

    // MARK: - Transcription Settings

    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet { defaults.set(transcriptionLanguage.rawValue, forKey: Keys.transcriptionLanguage) }
    }

    @Published var autoDetectLanguage: Bool {
        didSet { defaults.set(autoDetectLanguage, forKey: Keys.autoDetectLanguage) }
    }

    @Published var audioSource: AudioSource {
        didSet { defaults.set(audioSource.rawValue, forKey: Keys.audioSource) }
    }

    @Published var transcriptionAccuracy: TranscriptionAccuracy {
        didSet { defaults.set(transcriptionAccuracy.rawValue, forKey: Keys.transcriptionAccuracy) }
    }

    @Published var audioChunkDuration: Double {
        didSet { defaults.set(audioChunkDuration, forKey: Keys.audioChunkDuration) }
    }

    @Published var silenceThreshold: Double {
        didSet { defaults.set(silenceThreshold, forKey: Keys.silenceThreshold) }
    }

    @Published var skipSilentChunks: Bool {
        didSet { defaults.set(skipSilentChunks, forKey: Keys.skipSilentChunks) }
    }

    // MARK: - Prediction Settings

    @Published var predictionUpdateInterval: Double {
        didSet {
            defaults.set(predictionUpdateInterval, forKey: Keys.predictionUpdateInterval)
            PredictionEngine.shared.updateInterval = predictionUpdateInterval
        }
    }

    @Published var maxPredictionsToShow: Int {
        didSet { defaults.set(maxPredictionsToShow, forKey: Keys.maxPredictionsToShow) }
    }

    @Published var minConfidenceThreshold: Int {
        didSet {
            defaults.set(minConfidenceThreshold, forKey: Keys.minConfidenceThreshold)
            PredictionEngine.shared.minConfidenceThreshold = minConfidenceThreshold
        }
    }

    @Published var showConfidenceScores: Bool {
        didSet { defaults.set(showConfidenceScores, forKey: Keys.showConfidenceScores) }
    }

    @Published var showPredictionCategories: Bool {
        didSet { defaults.set(showPredictionCategories, forKey: Keys.showPredictionCategories) }
    }

    @Published var autoCopyHighConfidence: Bool {
        didSet { defaults.set(autoCopyHighConfidence, forKey: Keys.autoCopyHighConfidence) }
    }

    @Published var autoCopyThreshold: Int {
        didSet { defaults.set(autoCopyThreshold, forKey: Keys.autoCopyThreshold) }
    }

    @Published var playSoundOnPrediction: Bool {
        didSet { defaults.set(playSoundOnPrediction, forKey: Keys.playSoundOnPrediction) }
    }

    @Published var predictionCacheDuration: Double {
        didSet {
            defaults.set(predictionCacheDuration, forKey: Keys.predictionCacheDuration)
            PredictionEngine.shared.cacheValidityDuration = predictionCacheDuration
        }
    }

    // MARK: - UI Settings

    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Keys.displayMode) }
    }

    @Published var showFloatingOnLaunch: Bool {
        didSet { defaults.set(showFloatingOnLaunch, forKey: Keys.showFloatingOnLaunch) }
    }

    @Published var floatingWindowPosition: FloatingWindowPosition {
        didSet { defaults.set(floatingWindowPosition.rawValue, forKey: Keys.floatingWindowPosition) }
    }

    @Published var floatingWindowOpacity: Double {
        didSet {
            defaults.set(floatingWindowOpacity, forKey: Keys.floatingWindowOpacity)
            FloatingWindowManager.shared.updateOpacity(CGFloat(floatingWindowOpacity))
        }
    }

    @Published var fontSize: Double {
        didSet {
            defaults.set(fontSize, forKey: Keys.fontSize)
            FloatingWindowManager.shared.updateFontSize(CGFloat(fontSize))
        }
    }

    @Published var compactMode: Bool {
        didSet { defaults.set(compactMode, forKey: Keys.compactMode) }
    }

    @Published var showNotifications: Bool {
        didSet { defaults.set(showNotifications, forKey: Keys.showNotifications) }
    }

    @Published var badgeMenuBarIcon: Bool {
        didSet { defaults.set(badgeMenuBarIcon, forKey: Keys.badgeMenuBarIcon) }
    }

    // MARK: - Advanced Settings

    @Published var targetTokenLimit: Int {
        didSet { defaults.set(targetTokenLimit, forKey: Keys.targetTokenLimit) }
    }

    @Published var maxTranscriptionMessages: Int {
        didSet { defaults.set(maxTranscriptionMessages, forKey: Keys.maxTranscriptionMessages) }
    }

    @Published var maxScreenStates: Int {
        didSet { defaults.set(maxScreenStates, forKey: Keys.maxScreenStates) }
    }

    @Published var claudeModel: String {
        didSet {
            defaults.set(claudeModel, forKey: Keys.claudeModel)
            updateClaudeModel()
        }
    }

    @Published var debugLogging: Bool {
        didSet { defaults.set(debugLogging, forKey: Keys.debugLogging) }
    }

    @Published var showTokenCounts: Bool {
        didSet { defaults.set(showTokenCounts, forKey: Keys.showTokenCounts) }
    }

    // MARK: - Initialization

    private init() {
        // Load all settings from UserDefaults with defaults
        self.hasClaudeAPIKey = defaults.bool(forKey: Keys.hasClaudeAPIKey)
        self.hasOpenAIAPIKey = defaults.bool(forKey: Keys.hasOpenAIAPIKey)

        self.transcriptionLanguage = TranscriptionLanguage(
            rawValue: defaults.string(forKey: Keys.transcriptionLanguage) ?? "en"
        ) ?? .english
        self.autoDetectLanguage = defaults.object(forKey: Keys.autoDetectLanguage) as? Bool ?? false
        self.audioSource = AudioSource(
            rawValue: defaults.string(forKey: Keys.audioSource) ?? "system"
        ) ?? .system
        self.transcriptionAccuracy = TranscriptionAccuracy(
            rawValue: defaults.string(forKey: Keys.transcriptionAccuracy) ?? "balanced"
        ) ?? .balanced
        self.audioChunkDuration = defaults.object(forKey: Keys.audioChunkDuration) as? Double ?? 5.0
        self.silenceThreshold = defaults.object(forKey: Keys.silenceThreshold) as? Double ?? 0.01
        self.skipSilentChunks = defaults.object(forKey: Keys.skipSilentChunks) as? Bool ?? true

        self.predictionUpdateInterval = defaults.object(forKey: Keys.predictionUpdateInterval) as? Double ?? 12.0
        self.maxPredictionsToShow = defaults.object(forKey: Keys.maxPredictionsToShow) as? Int ?? 3
        self.minConfidenceThreshold = defaults.object(forKey: Keys.minConfidenceThreshold) as? Int ?? 4
        self.showConfidenceScores = defaults.object(forKey: Keys.showConfidenceScores) as? Bool ?? true
        self.showPredictionCategories = defaults.object(forKey: Keys.showPredictionCategories) as? Bool ?? true
        self.autoCopyHighConfidence = defaults.object(forKey: Keys.autoCopyHighConfidence) as? Bool ?? false
        self.autoCopyThreshold = defaults.object(forKey: Keys.autoCopyThreshold) as? Int ?? 9
        self.playSoundOnPrediction = defaults.object(forKey: Keys.playSoundOnPrediction) as? Bool ?? false
        self.predictionCacheDuration = defaults.object(forKey: Keys.predictionCacheDuration) as? Double ?? 30.0

        self.displayMode = DisplayMode(
            rawValue: defaults.string(forKey: Keys.displayMode) ?? "menuBar"
        ) ?? .menuBar
        self.showFloatingOnLaunch = defaults.object(forKey: Keys.showFloatingOnLaunch) as? Bool ?? false
        self.floatingWindowPosition = FloatingWindowPosition(
            rawValue: defaults.string(forKey: Keys.floatingWindowPosition) ?? "topRight"
        ) ?? .topRight
        self.floatingWindowOpacity = defaults.object(forKey: Keys.floatingWindowOpacity) as? Double ?? 0.95
        self.fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 11.0
        self.compactMode = defaults.object(forKey: Keys.compactMode) as? Bool ?? false
        self.showNotifications = defaults.object(forKey: Keys.showNotifications) as? Bool ?? true
        self.badgeMenuBarIcon = defaults.object(forKey: Keys.badgeMenuBarIcon) as? Bool ?? true

        self.targetTokenLimit = defaults.object(forKey: Keys.targetTokenLimit) as? Int ?? 2000
        self.maxTranscriptionMessages = defaults.object(forKey: Keys.maxTranscriptionMessages) as? Int ?? 15
        self.maxScreenStates = defaults.object(forKey: Keys.maxScreenStates) as? Int ?? 5
        self.claudeModel = defaults.string(forKey: Keys.claudeModel) ?? "claude-3-haiku-20240307"
        self.debugLogging = defaults.object(forKey: Keys.debugLogging) as? Bool ?? false
        self.showTokenCounts = defaults.object(forKey: Keys.showTokenCounts) as? Bool ?? false

        // Apply settings to components
        applySettings()
    }

    // MARK: - Methods

    func save() {
        defaults.synchronize()
    }

    func resetToDefaults() {
        // Remove all keys
        Keys.allKeys.forEach { defaults.removeObject(forKey: $0) }

        // Reload with defaults
        transcriptionLanguage = .english
        autoDetectLanguage = false
        audioSource = .system
        transcriptionAccuracy = .balanced
        audioChunkDuration = 5.0
        silenceThreshold = 0.01
        skipSilentChunks = true

        predictionUpdateInterval = 12.0
        maxPredictionsToShow = 3
        minConfidenceThreshold = 4
        showConfidenceScores = true
        showPredictionCategories = true
        autoCopyHighConfidence = false
        autoCopyThreshold = 9
        playSoundOnPrediction = false
        predictionCacheDuration = 30.0

        displayMode = .menuBar
        showFloatingOnLaunch = false
        floatingWindowPosition = .topRight
        floatingWindowOpacity = 0.95
        fontSize = 11.0
        compactMode = false
        showNotifications = true
        badgeMenuBarIcon = true

        targetTokenLimit = 2000
        maxTranscriptionMessages = 15
        maxScreenStates = 5
        claudeModel = "claude-3-haiku-20240307"
        debugLogging = false
        showTokenCounts = false

        applySettings()
    }

    private func applySettings() {
        // Apply to PredictionEngine
        PredictionEngine.shared.updateInterval = predictionUpdateInterval
        PredictionEngine.shared.minConfidenceThreshold = minConfidenceThreshold
        PredictionEngine.shared.cacheValidityDuration = predictionCacheDuration

        // Apply to AudioMonitor
        AudioMonitor.shared.chunkDuration = audioChunkDuration
        AudioMonitor.shared.silenceThreshold = Float(silenceThreshold)

        // Apply to FloatingWindowManager
        FloatingWindowManager.shared.defaultOpacity = CGFloat(floatingWindowOpacity)
        FloatingWindowManager.shared.defaultFontSize = CGFloat(fontSize)

        // Apply Claude model
        updateClaudeModel()
    }

    private func updateClaudeModel() {
        if let model = Model(rawValue: claudeModel) {
            ClaudeAPIClient.shared.model = model
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let hasClaudeAPIKey = "hasClaudeAPIKey"
        static let hasOpenAIAPIKey = "hasOpenAIAPIKey"

        static let transcriptionLanguage = "transcriptionLanguage"
        static let autoDetectLanguage = "autoDetectLanguage"
        static let audioSource = "audioSource"
        static let transcriptionAccuracy = "transcriptionAccuracy"
        static let audioChunkDuration = "audioChunkDuration"
        static let silenceThreshold = "silenceThreshold"
        static let skipSilentChunks = "skipSilentChunks"

        static let predictionUpdateInterval = "predictionUpdateInterval"
        static let maxPredictionsToShow = "maxPredictionsToShow"
        static let minConfidenceThreshold = "minConfidenceThreshold"
        static let showConfidenceScores = "showConfidenceScores"
        static let showPredictionCategories = "showPredictionCategories"
        static let autoCopyHighConfidence = "autoCopyHighConfidence"
        static let autoCopyThreshold = "autoCopyThreshold"
        static let playSoundOnPrediction = "playSoundOnPrediction"
        static let predictionCacheDuration = "predictionCacheDuration"

        static let displayMode = "displayMode"
        static let showFloatingOnLaunch = "showFloatingOnLaunch"
        static let floatingWindowPosition = "floatingWindowPosition"
        static let floatingWindowOpacity = "floatingWindowOpacity"
        static let fontSize = "fontSize"
        static let compactMode = "compactMode"
        static let showNotifications = "showNotifications"
        static let badgeMenuBarIcon = "badgeMenuBarIcon"

        static let targetTokenLimit = "targetTokenLimit"
        static let maxTranscriptionMessages = "maxTranscriptionMessages"
        static let maxScreenStates = "maxScreenStates"
        static let claudeModel = "claudeModel"
        static let debugLogging = "debugLogging"
        static let showTokenCounts = "showTokenCounts"

        static var allKeys: [String] {
            [
                hasClaudeAPIKey, hasOpenAIAPIKey,
                transcriptionLanguage, autoDetectLanguage, audioSource, transcriptionAccuracy,
                audioChunkDuration, silenceThreshold, skipSilentChunks,
                predictionUpdateInterval, maxPredictionsToShow, minConfidenceThreshold,
                showConfidenceScores, showPredictionCategories, autoCopyHighConfidence,
                autoCopyThreshold, playSoundOnPrediction, predictionCacheDuration,
                displayMode, showFloatingOnLaunch, floatingWindowPosition,
                floatingWindowOpacity, fontSize, compactMode, showNotifications, badgeMenuBarIcon,
                targetTokenLimit, maxTranscriptionMessages, maxScreenStates,
                claudeModel, debugLogging, showTokenCounts
            ]
        }
    }
}

// MARK: - Enums

enum TranscriptionLanguage: String, CaseIterable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case russian = "ru"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .dutch: return "Dutch"
        case .russian: return "Russian"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        }
    }
}

enum AudioSource: String, CaseIterable {
    case system = "system"
    case microphone = "microphone"
    case both = "both"
}

enum TranscriptionAccuracy: String, CaseIterable {
    case fast = "fast"
    case balanced = "balanced"
    case accurate = "accurate"
}

enum DisplayMode: String, CaseIterable {
    case menuBar = "menuBar"
    case floating = "floating"
    case both = "both"
}
