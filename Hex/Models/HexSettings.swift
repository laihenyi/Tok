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
struct HexSettings: Codable, Equatable {
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
    var enableScreenCapture: Bool = false // New setting for enabling screen capture
    var hasCompletedOnboarding: Bool = false // New setting for onboarding completion

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
    var selectedRemoteModel: String = "compound-beta-mini"
    // Voice Recognition Initial Prompt
    var voiceRecognitionPrompt: String = ""
    // Image Recognition Model settings
    var selectedImageModel: String = "llava:latest"
    var selectedRemoteImageModel: String = "llava-v1.5-7b-4096-preview"
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
        case enableScreenCapture
        case hasCompletedOnboarding
        case useAIEnhancement
        case selectedAIModel
        case aiEnhancementPrompt
        case aiEnhancementTemperature
        case aiProviderType
        case groqAPIKey
        case selectedRemoteModel
        case voiceRecognitionPrompt
        case transcriptionModelWarmStatus
        case selectedImageModel
        case selectedRemoteImageModel
        case imageAnalysisPrompt
        case developerModeEnabled
	}

	init(
		soundEffectsEnabled: Bool = true,
		hotkey: HotKey = .init(key: nil, modifiers: [.option]),
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
		selectedModel: String = "openai_whisper-large-v3-v20240930",
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		pauseMediaOnRecord: Bool = true,
		minimumKeyTime: Double = 0.2,
		copyToClipboard: Bool = true,
		useDoubleTapOnly: Bool = false,
		outputLanguage: String? = nil,
		selectedMicrophoneID: String? = nil,
        disableAutoCapitalization: Bool = false,
        enableScreenCapture: Bool = false,
        hasCompletedOnboarding: Bool = false,
        useAIEnhancement: Bool = false,
        selectedAIModel: String = "gemma3",
        aiEnhancementPrompt: String = EnhancementOptions.defaultPrompt,
        aiEnhancementTemperature: Double = 0.3,
        aiProviderType: AIProviderType = .ollama,
        groqAPIKey: String = "",
        selectedRemoteModel: String = "compound-beta-mini",
        voiceRecognitionPrompt: String = "",
        transcriptionModelWarmStatus: ModelWarmStatus = .cold,
        selectedImageModel: String = "llava:latest",
        selectedRemoteImageModel: String = "llava-v1.5-7b-4096-preview",
        imageAnalysisPrompt: String = defaultImageAnalysisPrompt,
        developerModeEnabled: Bool = false
	) {
		self.soundEffectsEnabled = soundEffectsEnabled
		self.hotkey = hotkey
		self.openOnLogin = openOnLogin
		self.showDockIcon = showDockIcon
		self.selectedModel = selectedModel
		self.useClipboardPaste = useClipboardPaste
		self.preventSystemSleep = preventSystemSleep
		self.pauseMediaOnRecord = pauseMediaOnRecord
		self.minimumKeyTime = minimumKeyTime
		self.copyToClipboard = copyToClipboard
		self.useDoubleTapOnly = useDoubleTapOnly
		self.outputLanguage = outputLanguage
		self.selectedMicrophoneID = selectedMicrophoneID
        self.disableAutoCapitalization = disableAutoCapitalization
        self.enableScreenCapture = enableScreenCapture
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.useAIEnhancement = useAIEnhancement
        self.selectedAIModel = selectedAIModel
        self.aiEnhancementPrompt = aiEnhancementPrompt
        self.aiEnhancementTemperature = aiEnhancementTemperature
        self.aiProviderType = aiProviderType
        self.groqAPIKey = groqAPIKey
        self.selectedRemoteModel = selectedRemoteModel
        self.voiceRecognitionPrompt = voiceRecognitionPrompt
        self.transcriptionModelWarmStatus = transcriptionModelWarmStatus
        self.selectedImageModel = selectedImageModel
        self.selectedRemoteImageModel = selectedRemoteImageModel
        self.imageAnalysisPrompt = imageAnalysisPrompt
        self.developerModeEnabled = developerModeEnabled
	}

	// Custom decoder that handles missing fields
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)

		// Decode each property, using decodeIfPresent with default fallbacks
		soundEffectsEnabled =
			try container.decodeIfPresent(Bool.self, forKey: .soundEffectsEnabled) ?? true
		hotkey =
			try container.decodeIfPresent(HotKey.self, forKey: .hotkey)
			?? .init(key: nil, modifiers: [.option])
		openOnLogin = try container.decodeIfPresent(Bool.self, forKey: .openOnLogin) ?? false
		showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
		selectedModel =
			try container.decodeIfPresent(String.self, forKey: .selectedModel)
			?? "openai_whisper-large-v3-v20240930"
		useClipboardPaste = try container.decodeIfPresent(Bool.self, forKey: .useClipboardPaste) ?? true
		preventSystemSleep =
			try container.decodeIfPresent(Bool.self, forKey: .preventSystemSleep) ?? true
		pauseMediaOnRecord =
			try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) ?? true
		minimumKeyTime =
			try container.decodeIfPresent(Double.self, forKey: .minimumKeyTime) ?? 0.2
		copyToClipboard =
			try container.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? true
		useDoubleTapOnly =
			try container.decodeIfPresent(Bool.self, forKey: .useDoubleTapOnly) ?? false
		outputLanguage = try container.decodeIfPresent(String.self, forKey: .outputLanguage)
        selectedMicrophoneID = try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
        disableAutoCapitalization = try container.decodeIfPresent(Bool.self, forKey: .disableAutoCapitalization) ?? false
        enableScreenCapture = try container.decodeIfPresent(Bool.self, forKey: .enableScreenCapture) ?? false
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        // AI Enhancement settings
        useAIEnhancement = try container.decodeIfPresent(Bool.self, forKey: .useAIEnhancement) ?? false
        selectedAIModel = try container.decodeIfPresent(String.self, forKey: .selectedAIModel) ?? "gemma3"
        aiEnhancementPrompt = try container.decodeIfPresent(String.self, forKey: .aiEnhancementPrompt) ?? EnhancementOptions.defaultPrompt
        aiEnhancementTemperature = try container.decodeIfPresent(Double.self, forKey: .aiEnhancementTemperature) ?? 0.3
        // Remote AI provider settings
        aiProviderType = try container.decodeIfPresent(AIProviderType.self, forKey: .aiProviderType) ?? .ollama
        groqAPIKey = try container.decodeIfPresent(String.self, forKey: .groqAPIKey) ?? ""
        selectedRemoteModel = try container.decodeIfPresent(String.self, forKey: .selectedRemoteModel) ?? "compound-beta-mini"
        // Voice Recognition Initial Prompt
        voiceRecognitionPrompt = try container.decodeIfPresent(String.self, forKey: .voiceRecognitionPrompt) ?? ""
        // Model warm status tracking (only for transcription models)
        transcriptionModelWarmStatus = try container.decodeIfPresent(ModelWarmStatus.self, forKey: .transcriptionModelWarmStatus) ?? .cold
        // Image Recognition Model settings
        selectedImageModel = try container.decodeIfPresent(String.self, forKey: .selectedImageModel) ?? "llava:latest"
        selectedRemoteImageModel = try container.decodeIfPresent(String.self, forKey: .selectedRemoteImageModel) ?? "llava-v1.5-7b-4096-preview"
        // Image Analysis Prompt
        imageAnalysisPrompt = try container.decodeIfPresent(String.self, forKey: .imageAnalysisPrompt) ?? defaultImageAnalysisPrompt
        // Developer options
        developerModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .developerModeEnabled) ?? false
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
    case groq = "groq"
    
    var displayName: String {
        switch self {
        case .ollama:
            return "Ollama (Local)"
        case .groq:
            return "Groq (Remote)"
        }
    }
    
    var description: String {
        switch self {
        case .ollama:
            return "Run AI models locally using Ollama"
        case .groq:
            return "Use Groq's fast inference API"
        }
    }
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
