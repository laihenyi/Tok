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
        
        // Computed property for convenient access to the default model
        var defaultAIModel: String {
            "gemma3"
        }
        
        // Current provider type
        var currentProvider: AIProviderType {
            hexSettings.aiProviderType
        }
        
        // Current selected model based on provider
        var currentSelectedModel: String {
            switch currentProvider {
            case .ollama:
                return hexSettings.selectedAIModel
            case .groq:
                return hexSettings.selectedRemoteModel
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
    }

    @Dependency(\.aiEnhancement) var aiEnhancement
    
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .send(.checkOllamaAvailability)
                
            case .checkOllamaAvailability:
                return .run { send in
                    let isAvailable = await aiEnhancement.isOllamaAvailable()
                    await send(.ollamaAvailabilityResult(isAvailable))
                }
                
            case let .ollamaAvailabilityResult(isAvailable):
                state.isOllamaAvailable = isAvailable
                
                // If current provider is Ollama and it's available, load models
                if isAvailable && state.currentProvider == .ollama {
                    return .send(.loadAvailableModels)
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
                        return .send(.loadAvailableModels)
                    }
                case .groq:
                    if !state.currentAPIKey.isEmpty {
                        return .send(.loadRemoteModels)
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
                    return .send(.loadRemoteModels)
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
            }
        }
    }
}