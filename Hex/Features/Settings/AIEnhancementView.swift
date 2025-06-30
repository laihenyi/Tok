// 
//  AIEnhancementView.swift
//  Hex
//
//  Created by Claude AI on 4/22/25.
//

import ComposableArchitecture
import SwiftUI

struct AIEnhancementView: View {
    @Bindable var store: StoreOf<AIEnhancementFeature>
    @State private var showExpandedPrompt = false
    @State private var showExpandedVoicePrompt = false
    @State private var showExpandedImagePrompt = false
    @State private var isHoveringModelSelect = false
    
    var body: some View {
        Form {
            // Activation Section (Always show this first)
            Section {
                activationToggle
            } header: {
                Text("AI Enhancement")
            } footer: {
                Text("Enable AI to improve transcription quality by fixing grammar, formatting, and errors.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            }
            
            // Only show other settings if AI enhancement is enabled
            if store.hexSettings.useAIEnhancement {
                // Provider Selection Section
                providerSelectionSection
                
                // API Key Section (only for remote providers)
                if store.currentProvider.category == .remote {
                    apiKeySection
                }
                
                // Connection Status Section (only show if there are issues or testing)
                if shouldShowConnectionStatus {
                    connectionStatusSection
                }
                
                // Model Selection Section
                modelSelectionSection

                // Screen Capture Section
                screenCaptureSection

                // Image Recognition Model Selection Section (only show if screen capture is enabled)
                if store.hexSettings.enableScreenCapture {
                    imageModelSelectionSection
                    
                    // Image Analysis Prompt Section (only show if screen capture is enabled)
                    imageAnalysisPromptSection
                }

                // Temperature Control Section
                temperatureSection
                
                // Prompt Configuration Section
                promptSection

                // Voice Recognition Initial Prompt Section
                voiceRecognitionPromptSection
            }
        }
        .formStyle(.grouped)
        .task {
            await store.send(.task).finish()
        }
    }
    
    // MARK: - Component Views
    
    // Provider Selection Section
    private var providerSelectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Provider picker
                Picker("AI Provider", selection: Binding(
                    get: { store.currentProvider },
                    set: { store.send(.setProviderType($0)) }
                )) {
                    ForEach(AIProviderType.allCases, id: \.self) { provider in
                        VStack(alignment: .leading) {
                            Text(provider.displayName)
                                .font(.body)
                            Text(provider.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        } header: {
            Text("AI Provider")
        } footer: {
            Text(providerFooterText)
                .foregroundColor(.secondary.opacity(0.7))
                .font(.caption)
        }
    }
    
    // API Key Section
    private var apiKeySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                SecureField("Enter API Key", text: Binding(
                    get: { store.currentAPIKey },
                    set: { store.send(.setAPIKey($0)) }
                ))
                .textFieldStyle(.roundedBorder)
                
                // Test connection button
                HStack {
                    Button("Test Connection") {
                        store.send(.testConnection)
                    }
                    .disabled(store.currentAPIKey.isEmpty || store.isTestingConnection)
                    
                    if store.isTestingConnection {
                        ProgressView()
                            .scaleEffect(0.8)
                            .padding(.leading, 8)
                    }
                    
                    Spacer()
                    
                    if let status = store.connectionStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundColor(status.contains("successful") ? .green : .red)
                    }
                }
            }
        } header: {
            Text("\(store.currentProvider.displayName) API Key")
        } footer: {
            Text(apiKeyFooterText)
                .foregroundColor(.secondary.opacity(0.7))
                .font(.caption)
        }
    }
    
    // Connection Status Section
    private var connectionStatusSection: some View {
        Section {
            connectionStatusView
        } header: {
            Text("Connection Status")
        }
    }
    
    // Computed properties for dynamic content
    private var shouldShowConnectionStatus: Bool {
        switch store.currentProvider {
        case .ollama, .lmstudio:
            return !store.isLocalProviderAvailable
        case .groq, .gemini:
            return store.currentAPIKey.isEmpty || (store.connectionStatus?.contains("failed") == true)
        }
    }
    
    private var providerFooterText: String {
        switch store.currentProvider {
        case .ollama:
            return "Run AI models locally using Ollama. Requires Ollama to be installed and running."
        case .groq:
            return "Use Groq's fast inference API. Requires a Groq API key."
        case .gemini:
            return "Use Google Gemini Generative Language API. Requires a Gemini API key."
        case .lmstudio:
            return "Run AI models locally using LM Studio. Requires LM Studio server to be running."
        default:
            return "Run AI models locally using LM Studio. Requires LM Studio server to be running."
        }
    }
    
    private var apiKeyFooterText: String {
        switch store.currentProvider {
        case .groq:
            return "Get your free API key from console.groq.com. Your key is stored securely on your device."
        case .gemini:
            return "Get an API key from Google AI Studio. Your key is stored securely on your device."
        default:
            return ""
        }
    }
    
    // Model selection helper properties
    private var canLoadModels: Bool {
        switch store.currentProvider {
        case .groq, .gemini:
            return !store.currentAPIKey.isEmpty
        default:
            return store.isLocalProviderAvailable
        }
    }
    
    private var hasAvailableModels: Bool {
        switch store.currentProvider {
        case .groq, .gemini:
            return !store.availableRemoteModels.isEmpty
        default:
            return !store.availableModels.isEmpty
        }
    }
    
    private var unavailableMessage: String {
        switch store.currentProvider {
        case .ollama:
            return "Ollama connection required to view models"
        case .groq, .gemini:
            return "API key required to load models"
        case .lmstudio:
            return "LM Studio server must be running to view models"
        }
    }
    
    private var noModelsMessage: String {
        switch store.currentProvider {
        case .ollama:
            return "No models found in Ollama"
        case .groq:
            return "No models available from Groq"
        case .gemini:
            return "No models available from Gemini"
        case .lmstudio:
            return "No models found in LM Studio"
        default:
            return "No models found"
        }
    }
    
    private var modelSelectionFooterText: String {
        switch store.currentProvider {
        case .groq:
            return "Different models offer various capabilities and speeds."
        case .gemini:
            return "Model capabilities vary between Gemini versions."
        default:
            return "Smaller models are faster but less capable."
        }
    }

    // Image model selection helper properties
    private var hasAvailableImageModels: Bool {
        switch store.currentProvider {
        case .groq, .gemini:
            return !store.availableRemoteImageModels.isEmpty
        default:
            return !store.availableImageModels.isEmpty
        }
    }

    private var noImageModelsMessage: String {
        switch store.currentProvider {
        case .ollama:
            return "No vision models found in Ollama"
        case .groq:
            return "No vision models available from Groq"
        case .gemini:
            return "No vision models available from Gemini"
        case .lmstudio:
            return "No vision models found in LM Studio"
        default:
            return "No vision models found"
        }
    }

    private var imageModelSelectionFooterText: String {
        switch store.currentProvider {
        case .ollama:
            return "Vision models like LLaVA can analyze screenshots and images. Install vision models in Ollama to enable image recognition."
        case .groq:
            return "Vision models can analyze screenshots and images to provide context for your transcriptions."
        case .gemini:
            return "Gemini vision models can analyze screenshots and images to provide context for your transcriptions."
        case .lmstudio:
            return "Vision models like LLaVA can analyze screenshots and images. Ensure the model is loaded in LM Studio."
        default:
            return "Vision models like LLaVA can analyze screenshots and images. Ensure the model is loaded in LM Studio."
        }
    }
    
    // Connection Status View
    private var connectionStatusView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(connectionStatusTitle)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(connectionStatusBody)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            if store.currentProvider.category == .local {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("To set up \(store.currentProvider.displayName):")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        if store.currentProvider == .ollama {
                            bulletPoint(text: "Download and install Ollama from [ollama.com](https://ollama.com)")
                            bulletPoint(text: "Launch the Ollama application")
                            bulletPoint(text: "Pull a language model (llama3 recommended)")
                        } else if store.currentProvider == .lmstudio {
                            bulletPoint(text: "Download and install LM Studio from [lmstudio.ai](https://lmstudio.ai)")
                            bulletPoint(text: "Launch LM Studio and ensure REST server is running on port 1234")
                            bulletPoint(text: "Load or pull a compatible model (e.g., llama3)")
                        }
                    }
                    .padding(.leading, 8)
                }
            }

            HStack {
                Spacer()
                if store.currentProvider.category == .local {
                    if store.currentProvider == .ollama {
                        Button {
                            NSWorkspace.shared.open(URL(string: "https://ollama.com")!)
                        } label: {
                            Label("Download Ollama", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .foregroundColor(.blue)
                    } else if store.currentProvider == .lmstudio {
                        Button {
                            NSWorkspace.shared.open(URL(string: "https://lmstudio.ai")!)
                        } label: {
                            Label("Download LM Studio", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .foregroundColor(.blue)
                    }
                }
                Button {
                    store.send(.checkAvailability(store.currentProvider))
                } label: {
                    Label("Check Connection", systemImage: "arrow.clockwise")
                }
                .buttonStyle(DefaultButtonStyle())
                .foregroundColor(.blue)
            }
            .padding(.top, 4)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
    
    private var connectionStatusTitle: String {
        switch store.currentProvider {
        case .ollama:
            return "Ollama Not Connected"
        case .lmstudio:
            return "LM Studio Not Connected"
        case .groq:
            return "Groq Connection Issue"
        case .gemini:
            return "Gemini Connection Issue"
        }
    }

    private var connectionStatusBody: String {
        switch store.currentProvider {
        case .ollama:
            return "AI enhancement requires Ollama to be installed and running locally."
        case .lmstudio:
            return "AI enhancement requires LM Studio's REST server to be running locally (port 1234)."
        case .groq, .gemini:
            return "Verify that your API key is correct and that you have internet connectivity."
        }
    }
    
    // Activation Toggle
    private var activationToggle: some View {
        VStack(spacing: 8) {
            // Main toggle row
            Toggle(isOn: Binding(
                get: { store.hexSettings.useAIEnhancement },
                set: { newValue in 
                    store.$hexSettings.withLock { $0.useAIEnhancement = newValue }
                    
                    // When enabling, check Ollama status
                    if newValue {
                        Task {
                            await store.send(.checkAvailability(store.currentProvider)).finish()
                        }
                    }
                }
            )) {
                Text("Use AI Enhancement")
                    .font(.body)
            }
            
            // Connection status indicator (only show if AI enhancement is enabled and Ollama is available)
            if store.hexSettings.useAIEnhancement && store.currentProvider.category == .local && store.isLocalProviderAvailable {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("\(store.currentProvider.displayName) Connected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.leading, 2)
            }
        }
    }
    
    // Model Selection Section
    private var modelSelectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Model selection header
                HStack {
                    Label {
                        Text("Text Model")
                            .font(.body)
                    } icon: {
                        Image(systemName: "brain")
                    }
                    
                    Spacer()

                    if store.isLoadingModels {
                        HStack {
                            Text(getCurrentSelectedModel().isEmpty ? "No model selected" : getCurrentSelectedModel())
                                .font(.body)
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        .padding(.vertical, 2)
                    } else if !canLoadModels {
                        // Provider not available message
                        Text(unavailableMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else if let error = store.errorMessage {
                        // Error message
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.red)
                            Text("Error: \(error)")
                                .font(.caption)
                                .foregroundColor(.red)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    } else if !hasAvailableModels {
                        // No models available
                        HStack(alignment: .center) {
                            Text(noModelsMessage)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            if store.currentProvider == .ollama {
                                Link("Browse Models", destination: URL(string: "https://ollama.com/library")!)
                                    .font(.subheadline)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 8)
                    } else {
                        switch store.currentProvider {
                        case .groq, .gemini:
                            Picker("", selection: Binding(
                                get: { store.hexSettings.selectedRemoteModel },
                                set: { store.send(.setSelectedRemoteModel($0)) }
                            )) {
                                ForEach(store.availableRemoteModels) { model in
                                    VStack(alignment: .leading) {
                                        Text(model.displayName)
                                            .font(.body)
                                        Text("by \(model.ownedBy) • \(model.contextWindow/1024)K context")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .tag(model.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        default:
                            Picker("", selection: Binding(
                                get: { store.hexSettings.selectedAIModel },
                                set: { store.send(.setSelectedModel($0)) }
                            )) {
                                ForEach(store.availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                    }
                    
                    // Refresh button for models
                    Button {
                        switch store.currentProvider {
                        case .groq, .gemini:
                            store.send(.loadRemoteModels)
                        default:
                            store.send(.loadAvailableModels)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body)
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .disabled(store.isLoadingModels || !canLoadModels)
                    .opacity(store.isLoadingModels ? 0.5 : 0.7)
                }

            }
        } header: {
            Text("Model Selection")
        } footer: {
            if hasAvailableModels {
                Text(modelSelectionFooterText)
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            }
        }
    }

    // Image Recognition Model Selection Section
    private var imageModelSelectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Model selection header
                HStack {
                    Label {
                        Text("Vision Model")
                            .font(.body)
                    } icon: {
                        Image(systemName: "eye")
                    }

                    Spacer()


                    if store.isLoadingImageModels {
                        HStack {
                            Text(getCurrentSelectedImageModel().isEmpty ? "No model selected" : getCurrentSelectedImageModel())
                                .font(.body)
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        .padding(.vertical, 2)
                    } else if !canLoadModels {
                        // Provider not available message
                        Text(unavailableMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else if let error = store.imageModelErrorMessage {
                        // Error message
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.red)
                            Text("Error: \(error)")
                                .font(.caption)
                                .foregroundColor(.red)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    } else if !hasAvailableImageModels {
                        // No image models available
                        HStack(alignment: .center) {
                            Text(noImageModelsMessage)
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Spacer()

                            if store.currentProvider == .ollama {
                                Link("Browse Vision Models", destination: URL(string: "https://ollama.com/library?q=vision")!)
                                    .font(.subheadline)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 8)
                    } else {
                        switch store.currentProvider {
                        case .groq, .gemini:
                            Picker("", selection: Binding(
                                get: { store.hexSettings.selectedRemoteImageModel },
                                set: { store.send(.setSelectedRemoteImageModel($0)) }
                            )) {
                                ForEach(store.availableRemoteImageModels) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        default:
                            Picker("", selection: Binding(
                                get: { store.hexSettings.selectedImageModel },
                                set: { store.send(.setSelectedImageModel($0)) }
                            )) {
                                ForEach(store.availableImageModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                    }

                    // Refresh button for image models
                    Button {
                        switch store.currentProvider {
                        case .groq, .gemini:
                            store.send(.loadRemoteImageModels)
                        default:
                            store.send(.loadAvailableImageModels)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body)
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .disabled(store.isLoadingImageModels || !canLoadModels)
                    .opacity(store.isLoadingImageModels ? 0.5 : 0.7)
                }

            }
        } header: {
            Text("Image Recognition")
        } footer: {
            if hasAvailableImageModels {
                Text(imageModelSelectionFooterText)
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            }
        }
    }

    // Temperature Section
    private var temperatureSection: some View {
        Section {
            // Label with temperature value
            HStack {
                Text("Response Style")
                    .font(.subheadline)
                
                Spacer()
                
                Text("\(store.hexSettings.aiEnhancementTemperature, specifier: "%.2f")")
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40)
            }
            .padding(.bottom, 4)
            
            // Slider for temperature control - extend even further
            ZStack {
                Slider(
                    value: Binding(
                        get: { store.hexSettings.aiEnhancementTemperature },
                        set: { newValue in
                            store.$hexSettings.withLock { $0.aiEnhancementTemperature = newValue }
                        }
                    ),
                    in: 0...1,
                    step: 0.05
                )
                .padding(.horizontal, -40)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 40)
            
            // Temperature descriptions
            HStack {
                Text("Precision")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("Creativity")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 0)
            .padding(.top, 4)
        } header: {
            Text("Response Style")
        } footer: {
            Text("Lower values produce more consistent, conservative improvements. Higher values allow more creative rewording.")
                .foregroundColor(.secondary.opacity(0.7))
                .font(.caption)
        }
    }
    
    // Prompt Configuration Section
    private var promptSection: some View {
        Section {
            VStack(spacing: 0) {
                // Header with edit button
                HStack {
                    Label {
                        Text("Instructions")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                    
                    Spacer()
                    
                    Button(showExpandedPrompt ? "Done" : "Edit") {
                        withAnimation(.spring(duration: 0.3)) {
                            showExpandedPrompt.toggle()
                        }
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .foregroundColor(showExpandedPrompt ? Color.primary : Color.accentColor)
                    .font(.caption)
                }
                .padding(.bottom, 8)
                
                if showExpandedPrompt {
                    // Expanded editor view
                    VStack(spacing: 8) {
                        // Editor
                        TextEditor(text: Binding(
                            get: { store.hexSettings.aiEnhancementPrompt },
                            set: { newValue in
                                store.$hexSettings.withLock { $0.aiEnhancementPrompt = newValue }
                            }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        
                        // Reset button
                        Button("Reset to Default") {
                            store.send(.resetToDefaultPrompt)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    // Collapsed preview
                    Text(store.hexSettings.aiEnhancementPrompt)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.05))
                        )
                }
            }
        } header: {
            Text("Enhancement Prompt")
        } footer: {
            if !showExpandedPrompt {
                Text("These instructions tell the AI how to improve your transcribed text.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            } else {
                Text("Make changes to customize how the AI enhances your transcriptions. Be specific about what should be preserved or changed.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            }
        }
    }

    // Voice Recognition Initial Prompt Section
    private var voiceRecognitionPromptSection: some View {
        Section {
            VStack(spacing: 0) {
                // Header with edit button
                HStack {
                    Label {
                        Text("Initial Prompt")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "mic.badge.plus")
                    }

                    Spacer()

                    Button(showExpandedVoicePrompt ? "Done" : "Edit") {
                        withAnimation(.spring(duration: 0.3)) {
                            showExpandedVoicePrompt.toggle()
                        }
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .foregroundColor(showExpandedVoicePrompt ? Color.primary : Color.accentColor)
                    .font(.caption)
                }
                .padding(.bottom, 8)

                if showExpandedVoicePrompt {
                    // Expanded editor view
                    VStack(spacing: 8) {
                        // Editor
                        TextEditor(text: Binding(
                            get: { store.hexSettings.voiceRecognitionPrompt },
                            set: { newValue in
                                store.$hexSettings.withLock { $0.voiceRecognitionPrompt = newValue }
                            }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                        // Clear button
                        Button("Clear") {
                            store.$hexSettings.withLock { $0.voiceRecognitionPrompt = "" }
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    // Collapsed preview or placeholder
                    if store.hexSettings.voiceRecognitionPrompt.isEmpty {
                        Text("No initial prompt set")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.05))
                            )
                    } else {
                        Text(store.hexSettings.voiceRecognitionPrompt)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.05))
                            )
                    }
                }
            }
        } header: {
            Text("Voice Recognition Prompt")
        } footer: {
            if !showExpandedVoicePrompt {
                Text("Optional context that helps Whisper better understand what you're likely to say. This is applied directly to voice recognition, not AI enhancement.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            } else {
                Text("Enter context or keywords that help Whisper recognize your speech more accurately. For example: technical terms, names, or domain-specific vocabulary you frequently use.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            }
        }
    }

    // Helper for bullet points
    private func bulletPoint(text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(LocalizedStringKey(text))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    // Helper to get currently selected model
    private func getCurrentSelectedModel() -> String {
        switch store.currentProvider {
        case .groq, .gemini:
            return store.hexSettings.selectedRemoteModel
        default:
            return store.hexSettings.selectedAIModel
        }
    }
    
    // Helper to get currently selected image model
    private func getCurrentSelectedImageModel() -> String {
        switch store.currentProvider {
        case .groq, .gemini:
            return store.hexSettings.selectedRemoteImageModel
        default:
            return store.hexSettings.selectedImageModel
        }
    }
    
    // Screen Capture Section
    private var screenCaptureSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { store.hexSettings.enableScreenCapture },
                    set: { newValue in 
                        store.$hexSettings.withLock { $0.enableScreenCapture = newValue }
                    }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable Screen Capture")
                                .font(.body)
                            Text("Allow capturing screenshots for AI image analysis and enhanced context understanding")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "camera.viewfinder")
                    }
                }
            }
        } header: {
            Text("Screen Capture")
        } footer: {
            Text("When enabled, screenshots will be captured and analyzed to provide better transcription context. This requires screen recording permission.")
                .foregroundColor(.secondary.opacity(0.7))
                .font(.caption)
        }
    }
    
    // Image Analysis Prompt Section
    private var imageAnalysisPromptSection: some View {
        Section {
            VStack(spacing: 0) {
                // Header with edit button
                HStack {
                    Label {
                        Text("Analysis Instructions")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "photo.badge.plus")
                    }
                    
                    Spacer()
                    
                    Button(showExpandedImagePrompt ? "Done" : "Edit") {
                        withAnimation(.spring(duration: 0.3)) {
                            showExpandedImagePrompt.toggle()
                        }
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .foregroundColor(showExpandedImagePrompt ? Color.primary : Color.accentColor)
                    .font(.caption)
                }
                .padding(.bottom, 8)
                
                if showExpandedImagePrompt {
                    // Expanded editor view
                    VStack(spacing: 8) {
                        // Editor
                        TextEditor(text: Binding(
                            get: { store.hexSettings.imageAnalysisPrompt },
                            set: { newValue in
                                store.$hexSettings.withLock { $0.imageAnalysisPrompt = newValue }
                            }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        
                        // Reset button
                        Button("Reset to Default") {
                            store.send(.resetToDefaultImagePrompt)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    // Collapsed preview
                    Text(store.hexSettings.imageAnalysisPrompt)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.05))
                        )
                }
            }
        } header: {
            Text("Image Analysis Prompt")
        } footer: {
            if !showExpandedImagePrompt {
                Text("These instructions tell the AI how to analyze captured screenshots for better transcription context.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            } else {
                Text("Customize how the AI analyzes screenshots. This affects the context information that helps improve transcription accuracy.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            }
        }
    }
}
