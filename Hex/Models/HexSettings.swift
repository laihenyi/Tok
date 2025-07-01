import ComposableArchitecture
import Dependencies
import Foundation

/// Model warm status tracking
enum ModelWarmStatus: String, Codable, Equatable {
    case cold = "cold"       // Model not loaded
    case warming = "warming" // Model currently loading/prewarming
    case warm = "warm"       // Model loaded and ready
}

// To add a new setting, add a new property to the struct, the CodingKeys enum, and the custom decoder
struct HexSettings: Codable, Equatable, Sendable {
	var soundEffectsEnabled: Bool = true
	var hotkey: HotKey = .init(key: nil, modifiers: [.option])
	var openOnLogin: Bool = false
	var showDockIcon: Bool = true
	var selectedModel: String = "openai_whisper-large-v3-v20240930"
	var useClipboardPaste: Bool = true
	var preventSystemSleep: Bool = true
	var pauseMediaOnRecord: Bool = true
	var minimumKeyTime: Double = 0.2
	var copyToClipboard: Bool = true
	var useDoubleTapOnly: Bool = false
	var outputLanguage: String? = nil
	var selectedMicrophoneID: String? = nil
    var disableAutoCapitalization: Bool = false // New setting for disabling auto-capitalization
    // Audio mixing settings for meetings
    var enableAudioMixing: Bool = false // Enable mixing input and output audio
    var selectedOutputDeviceID: String? = nil // Output device to capture audio from
    var audioMixingInputGain: Double = 1.0 // Gain for microphone input (0.0 - 2.0)
    var audioMixingSystemAudioGain: Double = 1.0 // Gain for system output (0.0 - 2.0)
    var backgroundOpacity: Double = 0.6 // Background opacity for karaoke view (0.0 - 1.0)
    var karaokeFontSize: Double = 28.0 // Font size for karaoke view text (12.0 - 72.0)
    var customThemeColors: [String] = [] // Custom color hex codes for theme picker
    var enableScreenCapture: Bool = false // New setting for enabling screen capture
    var karaokeHotKey: HotKey = .init(key: .k, modifiers: [.command, .shift])
    var hasCompletedOnboarding: Bool = false // New setting for onboarding completion
    var karaokeBackgroundText: String = ""

    // Model warm status tracking (only for transcription models that need prewarming)
    var transcriptionModelWarmStatus: ModelWarmStatus = .cold
    // AI Enhancement options
    var useAIEnhancement: Bool = false
    var selectedAIModel: String = "gemma3"
    var aiEnhancementPrompt: String = EnhancementOptions.defaultPrompt
    var aiEnhancementTemperature: Double = 0.3
    // Remote AI provider settings
    var aiProviderType: AIProviderType = .ollama
    var groqAPIKey: String = ""
    var geminiAPIKey: String = ""
    var selectedRemoteModel: String = "llama-3.3-70b-versatile"
    // Voice Recognition Initial Prompt
    var voiceRecognitionPrompt: String = ""
    // Live response (karaoke) prompt
    var liveResponsePrompt: String = ""
    // Image Recognition Model settings
    var selectedImageModel: String = "gemma3n"
    var selectedRemoteImageModel: String = "meta-llama/llama-4-maverick-17b-128e-instruct"
    // Image Analysis Prompt
    var imageAnalysisPrompt: String = defaultImageAnalysisPrompt
    // Developer options
    var developerModeEnabled: Bool = false // Hidden developer mode flag

	// Define coding keys to match struct properties
	enum CodingKeys: String, CodingKey {
		case soundEffectsEnabled
		case hotkey
		case openOnLogin
		case showDockIcon
		case selectedModel
		case useClipboardPaste
		case preventSystemSleep
		case pauseMediaOnRecord
		case minimumKeyTime
		case copyToClipboard
		case useDoubleTapOnly
		case outputLanguage
		case selectedMicrophoneID
        case disableAutoCapitalization
        case enableAudioMixing
        case selectedOutputDeviceID
        case audioMixingInputGain
        case audioMixingSystemAudioGain
        case backgroundOpacity
        case karaokeFontSize
        case customThemeColors
        case enableScreenCapture
        case karaokeHotKey
        case hasCompletedOnboarding
        case useAIEnhancement
        case selectedAIModel
        case aiEnhancementPrompt
        case aiEnhancementTemperature
        case aiProviderType
        case groqAPIKey
        case geminiAPIKey
        case selectedRemoteModel
        case voiceRecognitionPrompt
        case liveResponsePrompt
        case transcriptionModelWarmStatus
        case selectedImageModel
        case selectedRemoteImageModel
        case imageAnalysisPrompt
        case developerModeEnabled
        case karaokeBackgroundText
	}

	/// Default initializer that relies on all stored-property default values.
	/// Needed because the presence of a custom `init(from:)` prevents Swift from
	/// synthesising the zero-argument initializer that other code expects.
	init() {}

	// Custom decoder that handles missing fields
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		// A fresh instance gives us all default values in one place so we don't have to
		// duplicate literals here.
		let defaults = HexSettings()

		soundEffectsEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEffectsEnabled) ?? defaults.soundEffectsEnabled
		hotkey = try container.decodeIfPresent(HotKey.self, forKey: .hotkey) ?? defaults.hotkey
		openOnLogin = try container.decodeIfPresent(Bool.self, forKey: .openOnLogin) ?? defaults.openOnLogin
		showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? defaults.showDockIcon
		selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel) ?? defaults.selectedModel
		useClipboardPaste = try container.decodeIfPresent(Bool.self, forKey: .useClipboardPaste) ?? defaults.useClipboardPaste
		preventSystemSleep = try container.decodeIfPresent(Bool.self, forKey: .preventSystemSleep) ?? defaults.preventSystemSleep
		pauseMediaOnRecord = try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) ?? defaults.pauseMediaOnRecord
		minimumKeyTime = try container.decodeIfPresent(Double.self, forKey: .minimumKeyTime) ?? defaults.minimumKeyTime
		copyToClipboard = try container.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? defaults.copyToClipboard
		useDoubleTapOnly = try container.decodeIfPresent(Bool.self, forKey: .useDoubleTapOnly) ?? defaults.useDoubleTapOnly
		outputLanguage = try container.decodeIfPresent(String.self, forKey: .outputLanguage) ?? defaults.outputLanguage
        selectedMicrophoneID = try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID) ?? defaults.selectedMicrophoneID
        disableAutoCapitalization = try container.decodeIfPresent(Bool.self, forKey: .disableAutoCapitalization) ?? defaults.disableAutoCapitalization
        enableAudioMixing = try container.decodeIfPresent(Bool.self, forKey: .enableAudioMixing) ?? defaults.enableAudioMixing
        selectedOutputDeviceID = try container.decodeIfPresent(String.self, forKey: .selectedOutputDeviceID) ?? defaults.selectedOutputDeviceID
        audioMixingInputGain = try container.decodeIfPresent(Double.self, forKey: .audioMixingInputGain) ?? defaults.audioMixingInputGain
        audioMixingSystemAudioGain = try container.decodeIfPresent(Double.self, forKey: .audioMixingSystemAudioGain) ?? defaults.audioMixingSystemAudioGain
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? defaults.backgroundOpacity
        karaokeFontSize = try container.decodeIfPresent(Double.self, forKey: .karaokeFontSize) ?? defaults.karaokeFontSize
        customThemeColors = try container.decodeIfPresent([String].self, forKey: .customThemeColors) ?? defaults.customThemeColors
        enableScreenCapture = try container.decodeIfPresent(Bool.self, forKey: .enableScreenCapture) ?? defaults.enableScreenCapture
        karaokeHotKey = try container.decodeIfPresent(HotKey.self, forKey: .karaokeHotKey) ?? defaults.karaokeHotKey
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? defaults.hasCompletedOnboarding
        karaokeBackgroundText = try container.decodeIfPresent(String.self, forKey: .karaokeBackgroundText) ?? defaults.karaokeBackgroundText
        
        // AI Enhancement
        useAIEnhancement = try container.decodeIfPresent(Bool.self, forKey: .useAIEnhancement) ?? defaults.useAIEnhancement
        selectedAIModel = try container.decodeIfPresent(String.self, forKey: .selectedAIModel) ?? defaults.selectedAIModel
        aiEnhancementPrompt = try container.decodeIfPresent(String.self, forKey: .aiEnhancementPrompt) ?? defaults.aiEnhancementPrompt
        aiEnhancementTemperature = try container.decodeIfPresent(Double.self, forKey: .aiEnhancementTemperature) ?? defaults.aiEnhancementTemperature
        
        // Remote AI provider settings
        aiProviderType = try container.decodeIfPresent(AIProviderType.self, forKey: .aiProviderType) ?? defaults.aiProviderType
        groqAPIKey = try container.decodeIfPresent(String.self, forKey: .groqAPIKey) ?? defaults.groqAPIKey
        geminiAPIKey = try container.decodeIfPresent(String.self, forKey: .geminiAPIKey) ?? defaults.geminiAPIKey
        selectedRemoteModel = try container.decodeIfPresent(String.self, forKey: .selectedRemoteModel) ?? defaults.selectedRemoteModel
        
        // Voice Recognition
        voiceRecognitionPrompt = try container.decodeIfPresent(String.self, forKey: .voiceRecognitionPrompt) ?? defaults.voiceRecognitionPrompt
        liveResponsePrompt = try container.decodeIfPresent(String.self, forKey: .liveResponsePrompt) ?? defaults.liveResponsePrompt
        
        // Model warm status
        transcriptionModelWarmStatus = try container.decodeIfPresent(ModelWarmStatus.self, forKey: .transcriptionModelWarmStatus) ?? defaults.transcriptionModelWarmStatus
        
        // Image Recognition
        selectedImageModel = try container.decodeIfPresent(String.self, forKey: .selectedImageModel) ?? defaults.selectedImageModel
        selectedRemoteImageModel = try container.decodeIfPresent(String.self, forKey: .selectedRemoteImageModel) ?? defaults.selectedRemoteImageModel
        imageAnalysisPrompt = try container.decodeIfPresent(String.self, forKey: .imageAnalysisPrompt) ?? defaults.imageAnalysisPrompt
        
        developerModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .developerModeEnabled) ?? defaults.developerModeEnabled
	}
}

/// Default prompt for image analysis
let defaultImageAnalysisPrompt = """
You are an AI assistant that analyzes screenshots to provide context for transcription.

Your task is to:
1. Describe what the user is currently working on based on the screenshot
2. Identify any visible text, UI elements, applications, or content that might be relevant
3. Respond in first person format (e.g., "I'm working on...")
4. Keep your response concise and focused on context that would help improve speech-to-text accuracy
5. If you see specific technical terms, names, or domain-specific vocabulary, mention them

Provide a brief, contextual summary that would help a transcription system better understand what the user might be talking about.
"""

/// AI Provider types supported by the app
enum AIProviderType: String, Codable, CaseIterable, Equatable {
    case ollama = "ollama"
    /// Local LM Studio REST server (default port 1234)
    case lmstudio = "lmstudio"
    case groq = "groq"
    /// Google Gemini API (Generative Language)
    case gemini = "gemini"
    
    var displayName: String {
        switch self {
        case .ollama:
            return "Ollama (Local)"
        case .lmstudio:
            return "LM Studio (Local)"
        case .groq:
            return "Groq (Remote)"
        case .gemini:
            return "Gemini (Remote)"
        }
    }
    
    var description: String {
        switch self {
        case .ollama:
            return "Run AI models locally using Ollama"
        case .lmstudio:
            return "Run AI models locally using LM Studio"
        case .groq:
            return "Use Groq's fast inference API"
        case .gemini:
            return "Google Gemini Generative Language API"
        }
    }
}

/// High-level grouping of providers
enum AIProviderCategory: String, Codable, CaseIterable, Equatable {
    case local
    case remote
}

extension AIProviderType {
    /// Returns whether the provider is local (runs on-device) or remote (cloud).
    var category: AIProviderCategory {
        switch self {
        case .ollama, .lmstudio:
            return .local
        case .groq, .gemini:
            return .remote
        }
    }

    /// Convenience boolean
    var isLocal: Bool { category == .local }
}

// Cache for HexSettings to reduce disk I/O
private var cachedSettings: HexSettings? = nil
private var lastSettingsLoadTime: Date = .distantPast

// Helper function to get cached settings or load from disk
func getCachedSettings() -> HexSettings {
    // Use cached settings if they exist and are recent (within last 5 seconds)
    if let cached = cachedSettings, 
       Date().timeIntervalSince(lastSettingsLoadTime) < 5.0 {
        return cached
    }
    
    // Otherwise read from disk
    do {
        let url = URL.documentsDirectory.appending(component: "hex_settings.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let settings = try JSONDecoder().decode(HexSettings.self, from: data)
            
            // Update cache
            cachedSettings = settings
            lastSettingsLoadTime = Date()
            
            return settings
        }
    } catch {
        print("Error loading settings: \(error)")
    }
    
    // On error or if file doesn't exist, return default settings
    let defaultSettings = HexSettings()
    cachedSettings = defaultSettings
    lastSettingsLoadTime = Date()
    return defaultSettings
}

extension SharedReaderKey
	where Self == FileStorageKey<HexSettings>.Default
{
	static var hexSettings: Self {
		Self[
			.fileStorage(URL.documentsDirectory.appending(component: "hex_settings.json")),
			default: getCachedSettings()
		]
	}
}
