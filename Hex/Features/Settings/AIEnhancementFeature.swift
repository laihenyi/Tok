//
//  AIEnhancementFeature.swift
//  Hex
//
//  Created by Claude AI on 4/22/25.
//

import ComposableArchitecture
import Foundation
import SwiftUI

@Reducer
struct AIEnhancementFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.hexSettings) var hexSettings: HexSettings
        
        var isOllamaAvailable: Bool = false
        var availableModels: [String] = []
        var availableRemoteModels: [RemoteAIModel] = []
        var isLoadingModels: Bool = false
        var errorMessage: String? = nil
        var isTestingConnection: Bool = false
        var connectionStatus: String? = nil

        // Image recognition model state
        var availableImageModels: [String] = []
        var availableRemoteImageModels: [RemoteAIModel] = []
        var isLoadingImageModels: Bool = false
        var imageModelErrorMessage: String? = nil
        
        // Computed property for convenient access to the default model
        var defaultAIModel: String {
            "gemma3"
        }

        // Computed property for convenient access to the default image model
        var defaultImageModel: String {
            "llava:latest"
        }
        
        // Current provider type
        var currentProvider: AIProviderType {
            hexSettings.aiProviderType
        }

        // Current selected models
        var currentSelectedModel: String {
            switch currentProvider {
            case .ollama:
                return hexSettings.selectedAIModel
            case .groq:
                return hexSettings.selectedRemoteModel
            }
        }

        var currentSelectedImageModel: String {
            switch currentProvider {
            case .ollama:
                return hexSettings.selectedImageModel
            case .groq:
                return hexSettings.selectedRemoteImageModel
            }
        }

        // API key for current provider (if applicable)
        var currentAPIKey: String {
            switch currentProvider {
            case .ollama:
                return ""
            case .groq:
                return hexSettings.groqAPIKey
            }
        }
    }
    
    enum Action {
        case task
        case checkOllamaAvailability
        case ollamaAvailabilityResult(Bool)
        case loadAvailableModels
        case modelsLoaded([String])
        case modelLoadingError(String)
        case setSelectedModel(String)
        case resetToDefaultPrompt
        // Remote provider actions
        case setProviderType(AIProviderType)
        case setAPIKey(String)
        case testConnection
        case connectionTestResult(Bool, String?)
        case loadRemoteModels
        case remoteModelsLoaded([RemoteAIModel])
        case setSelectedRemoteModel(String)
        // Image model actions
        case loadAvailableImageModels
        case imageModelsLoaded([String])
        case imageModelLoadingError(String)
        case setSelectedImageModel(String)
        case loadRemoteImageModels
        case remoteImageModelsLoaded([RemoteAIModel])
        case setSelectedRemoteImageModel(String)
    }

    @Dependency(\.aiEnhancement) var aiEnhancement
    
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                // Check Ollama availability and load models for current provider
                if state.currentProvider == .groq && !state.currentAPIKey.isEmpty {
                    return .merge(
                        .send(.checkOllamaAvailability),
                        .send(.loadRemoteModels),
                        .send(.loadRemoteImageModels)
                    )
                } else {
                    return .send(.checkOllamaAvailability)
                }
                
            case .checkOllamaAvailability:
                return .run { send in
                    let isAvailable = await aiEnhancement.isOllamaAvailable()
                    await send(.ollamaAvailabilityResult(isAvailable))
                }
                
            case let .ollamaAvailabilityResult(isAvailable):
                state.isOllamaAvailable = isAvailable

                // If current provider is Ollama and it's available, load models
                if isAvailable && state.currentProvider == .ollama {
                    return .merge(
                        .send(.loadAvailableModels),
                        .send(.loadAvailableImageModels)
                    )
                }
                return .none
                
            case .loadAvailableModels:
                state.isLoadingModels = true
                state.errorMessage = nil
                
                return .run { send in
                    do {
                        let models = try await aiEnhancement.getAvailableModels()
                        await send(.modelsLoaded(models))
                    } catch {
                        await send(.modelLoadingError(error.localizedDescription))
                    }
                }
                
            case let .modelsLoaded(models):
                state.isLoadingModels = false
                state.availableModels = models
                
                // If the selected model is not in the list and we have models, select the first one
                if !models.isEmpty && !models.contains(state.hexSettings.selectedAIModel) {
                    // Check if the default model is available
                    if models.contains(state.defaultAIModel) {
                        state.$hexSettings.withLock { $0.selectedAIModel = state.defaultAIModel }
                    } else {
                        state.$hexSettings.withLock { $0.selectedAIModel = models[0] }
                    }
                }
                
                return .none
                
            case let .modelLoadingError(message):
                state.isLoadingModels = false
                state.errorMessage = message
                return .none
                
            case let .setSelectedModel(model):
                state.$hexSettings.withLock { $0.selectedAIModel = model }
                return .none
                
            case .resetToDefaultPrompt:
                state.$hexSettings.withLock { $0.aiEnhancementPrompt = EnhancementOptions.defaultPrompt }
                return .none
                
            // Remote provider actions
            case let .setProviderType(providerType):
                state.$hexSettings.withLock { $0.aiProviderType = providerType }
                state.errorMessage = nil
                state.connectionStatus = nil
                
                // Load appropriate models based on provider
                switch providerType {
                case .ollama:
                    if state.isOllamaAvailable {
                        return .merge(
                            .send(.loadAvailableModels),
                            .send(.loadAvailableImageModels)
                        )
                    }
                case .groq:
                    if !state.currentAPIKey.isEmpty {
                        return .merge(
                            .send(.loadRemoteModels),
                            .send(.loadRemoteImageModels)
                        )
                    }
                }
                return .none
                
            case let .setAPIKey(apiKey):
                switch state.currentProvider {
                case .ollama:
                    break // Ollama doesn't use API keys
                case .groq:
                    state.$hexSettings.withLock { $0.groqAPIKey = apiKey }
                }
                return .none
                
            case .testConnection:
                state.isTestingConnection = true
                state.connectionStatus = nil
                
                return .run { [provider = state.currentProvider, apiKey = state.currentAPIKey] send in
                    let isConnected = await aiEnhancement.testRemoteConnection(provider, apiKey)
                    let status = isConnected ? "Connection successful" : "Connection failed"
                    await send(.connectionTestResult(isConnected, status))
                }
                
            case let .connectionTestResult(isConnected, status):
                state.isTestingConnection = false
                state.connectionStatus = status
                
                if isConnected && state.currentProvider == .groq {
                    return .merge(
                        .send(.loadRemoteModels),
                        .send(.loadRemoteImageModels)
                    )
                }
                return .none
                
            case .loadRemoteModels:
                guard state.currentProvider != .ollama else { return .none }
                
                state.isLoadingModels = true
                state.errorMessage = nil
                
                return .run { [provider = state.currentProvider, apiKey = state.currentAPIKey] send in
                    do {
                        let models = try await aiEnhancement.getRemoteModels(provider, apiKey)
                        await send(.remoteModelsLoaded(models))
                    } catch {
                        await send(.modelLoadingError(error.localizedDescription))
                    }
                }
                
            case let .remoteModelsLoaded(models):
                state.isLoadingModels = false
                state.availableRemoteModels = models
                
                // If no model is selected or current model is not available, select the first one
                if !models.isEmpty {
                    let currentModel = state.currentSelectedModel
                    if currentModel.isEmpty || !models.contains(where: { $0.id == currentModel }) {
                        // Try to find a default model or use the first one
                        let defaultModel = models.first { $0.id.contains("compound-beta-mini") } ?? models.first
                        if let model = defaultModel {
                            state.$hexSettings.withLock { $0.selectedRemoteModel = model.id }
                        }
                    }
                }
                
                return .none
                
            case let .setSelectedRemoteModel(modelId):
                state.$hexSettings.withLock { $0.selectedRemoteModel = modelId }
                return .none

            // Image model actions
            case .loadAvailableImageModels:
                state.isLoadingImageModels = true
                state.imageModelErrorMessage = nil

                return .run { send in
                    do {
                        let models = try await aiEnhancement.getAvailableModels()
                        // Filter for vision/image models (models that contain "llava", "vision", or "minicpm")
                        let imageModels = models.filter { model in
                            model.lowercased().contains("llava") ||
                            model.lowercased().contains("vision") ||
                            model.lowercased().contains("minicpm") ||
                            model.lowercased().contains("moondream")
                        }
                        await send(.imageModelsLoaded(imageModels))
                    } catch {
                        await send(.imageModelLoadingError(error.localizedDescription))
                    }
                }

            case let .imageModelsLoaded(models):
                state.isLoadingImageModels = false
                state.availableImageModels = models

                // If the selected image model is not in the list and we have models, select the first one
                if !models.isEmpty && !models.contains(state.hexSettings.selectedImageModel) {
                    // Check if the default image model is available
                    if models.contains(state.defaultImageModel) {
                        state.$hexSettings.withLock { $0.selectedImageModel = state.defaultImageModel }
                    } else {
                        state.$hexSettings.withLock { $0.selectedImageModel = models[0] }
                    }
                }

                return .none

            case let .imageModelLoadingError(message):
                state.isLoadingImageModels = false
                state.imageModelErrorMessage = message
                return .none

            case let .setSelectedImageModel(model):
                state.$hexSettings.withLock { $0.selectedImageModel = model }
                return .none

            case .loadRemoteImageModels:
                state.isLoadingImageModels = true
                state.imageModelErrorMessage = nil

                return .run { [provider = state.currentProvider, apiKey = state.currentAPIKey] send in
                    do {
                        let models = try await aiEnhancement.getRemoteModels(provider, apiKey)
                        // Filter for vision/image models
                        let imageModels = models.filter { model in
                            model.id.lowercased().contains("llama-4") ||
                            model.id.lowercased().contains("llava") ||
                            model.id.lowercased().contains("vision") ||
                            model.id.lowercased().contains("minicpm") ||
                            model.id.lowercased().contains("moondream")
                        }
                        await send(.remoteImageModelsLoaded(imageModels))
                    } catch {
                        await send(.imageModelLoadingError(error.localizedDescription))
                    }
                }

            case let .remoteImageModelsLoaded(models):
                state.isLoadingImageModels = false
                state.availableRemoteImageModels = models

                // If no image model is selected or current model is not available, select the first one
                if !models.isEmpty {
                    let currentModel = state.currentSelectedImageModel
                    if currentModel.isEmpty || !models.contains(where: { $0.id == currentModel }) {
                        // Try to find a default model or use the first one
                        let defaultModel = models.first { $0.id.contains("llama-4") } ?? models.first
                        if let model = defaultModel {
                            state.$hexSettings.withLock { $0.selectedRemoteImageModel = model.id }
                        }
                    }
                }

                return .none

            case let .setSelectedRemoteImageModel(modelId):
                state.$hexSettings.withLock { $0.selectedRemoteImageModel = modelId }
                return .none
            }
        }
    }
}