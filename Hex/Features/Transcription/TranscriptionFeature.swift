//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import SwiftUI
import WhisperKit
import IOKit
import IOKit.pwr_mgt

// MARK: - Progress Tracking Structures

struct RecordingProgress: Equatable {
  var duration: TimeInterval = 0
  var averageLevel: Double = 0
  var peakLevel: Double = 0
  var shouldPlayAudioFeedback: Bool = false
  var recordingQuality: RecordingQuality = .unknown
  
  enum RecordingQuality: Equatable {
    case unknown
    case poor
    case good
    case excellent
  }
  
  mutating func update(meter: Meter, startTime: Date?) {
    if let startTime = startTime {
      duration = Date().timeIntervalSince(startTime)
    }
    
    averageLevel = meter.averagePower
    peakLevel = meter.peakPower
    
    // Determine recording quality based on audio levels
    if averageLevel > 0.7 {
      recordingQuality = .excellent
    } else if averageLevel > 0.4 {
      recordingQuality = .good
    } else if averageLevel > 0.1 {
      recordingQuality = .poor
    } else {
      recordingQuality = .unknown
    }
  }
}

struct EnhancementProgress: Equatable {
  var stage: Stage = .idle
  var message: String = ""
  var startTime: Date?
  var estimatedTimeRemaining: TimeInterval?
  
  enum Stage: Equatable {
    case idle
    case connecting
    case processing
    case finalizing
    case completed
    case error(String)
  }
  
  mutating func updateStage(_ newStage: Stage) {
    stage = newStage
    
    switch newStage {
    case .idle:
      message = ""
      startTime = nil
      estimatedTimeRemaining = nil
    case .connecting:
      message = "Connecting to AI service..."
      startTime = Date()
      estimatedTimeRemaining = 2.0
    case .processing:
      message = "Enhancing transcription..."
      estimatedTimeRemaining = 5.0
    case .finalizing:
      message = "Finalizing results..."
      estimatedTimeRemaining = 1.0
    case .completed:
      message = "Enhancement complete"
      estimatedTimeRemaining = nil
    case .error(let errorMessage):
      message = "Error: \(errorMessage)"
      estimatedTimeRemaining = nil
    }
  }
}

// MARK: - Streaming Transcription Types

struct StreamingTranscription: Equatable {
  var confirmedSegments: [TranscriptionSegment] = []
  var unconfirmedSegments: [TranscriptionSegment] = []
  var currentText: String = ""
  var isActive: Bool = false
  var startTime: Date?
  
  mutating func reset() {
    confirmedSegments = []
    unconfirmedSegments = []
    currentText = ""
    isActive = false
    startTime = nil
  }
  
  mutating func updateFromStream(_ update: StreamTranscriptionUpdate) {
    print("[StreamingTranscription] updateFromStream called")
    print("[StreamingTranscription] Before update - currentText: '\(currentText)'")
    print("[StreamingTranscription] Update currentText: '\(update.currentText)'")
    
    confirmedSegments = update.confirmedSegments
    unconfirmedSegments = update.unconfirmedSegments
    
    // Only update currentText if the new text is not empty, 
    // to prevent empty updates from overwriting previous transcription
    if !update.currentText.isEmpty {
      currentText = update.currentText
      print("[StreamingTranscription] Updated currentText to: '\(currentText)'")
    } else {
      print("[StreamingTranscription] Skipping empty currentText update")
    }
    
    if !isActive && !currentText.isEmpty {
      isActive = true
      startTime = Date()
      print("[StreamingTranscription] Activated streaming transcription")
    }
    
    print("[StreamingTranscription] After update - currentText: '\(currentText)', isActive: \(isActive)")
  }
}

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var isEnhancing: Bool = false // Add this to track when AI enhancement is active
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var assertionID: IOPMAssertionID?
    var pendingTranscription: String? // Store original transcription for fallback
    
    // Real-time feedback properties
    var recordingProgress: RecordingProgress = RecordingProgress()
    var enhancementProgress: EnhancementProgress = EnhancementProgress()
    var lastAudioFeedbackTime: Date = Date()
    var shouldShowRecordingPulse: Bool = false
    
    // Streaming transcription properties
    var streamingTranscription: StreamingTranscription = StreamingTranscription()
    var isStreamingTranscription: Bool = false
    
    // Prompt derived from screenshot analysis that is fed into Whisper for better recognition
    var contextPrompt: String? = nil
    
    // Alert state – set to true when a transcription potentially failed
    var showTranscriptionFailedAlert: Bool = false
    
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording

    // Cancel entire flow
    case cancel

    // Transcription result flow
    case transcriptionResult(String)
    case transcriptionError(Error)
    
    // AI Enhancement flow
    case setEnhancingState(Bool)
    case aiEnhancementResult(String)
    case aiEnhancementError(Error)
    case ollamaBecameUnavailable
    case recheckOllamaAvailability
    
    // Real-time feedback actions
    case updateRecordingProgress
    case updateEnhancementProgress(EnhancementProgress.Stage)
    case startRecordingPulse
    case stopRecordingPulse
    
    // Streaming transcription actions
    case streamTranscriptionUpdate(StreamTranscriptionUpdate)
    
    // Context prompt actions
    case setContextPrompt(String)

    // Model prewarming actions
    case prewarmSelectedModel
    case prewarmProgress(Double)
    case prewarmCompleted(Result<String, Error>)

    // Alert actions
    case setTranscriptionFailedAlert(Bool)
  }

  enum CancelID {
    case delayedRecord
    case metering
    case transcription
    case aiEnhancement
    case recordingFeedback
    case recordingPulse
    case enhancementFeedback
    case streamTranscription
    case prewarm
    case screenshotCapture
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.aiEnhancement) var aiEnhancement
  @Dependency(\.screenCapture) var screenCapture

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts three concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Prewarming the selected model
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          .send(.prewarmSelectedModel)
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        // Only update state.meter if it's significantly different from the previous value
        // or if we're currently recording (when we need more responsive updates)
        let averageDiff = abs(meter.averagePower - state.meter.averagePower)
        let peakDiff = abs(meter.peakPower - state.meter.peakPower)
        let significantChange = averageDiff > 0.03 || peakDiff > 0.05

        if state.isRecording || significantChange {
          state.meter = meter
        }
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // Ignore hotkey presses if we're already recording or transcribing to prevent
        // accidental double-clicks from cancelling ongoing operations
        guard !state.isRecording && !state.isTranscribing else {
          print("🎙️ [WARNING] Hotkey press ignored - recording or transcription already in progress")
          return .none
        }
        
        // Otherwise, proceed with normal hotkey handling
        return handleHotKeyPressed(isTranscribing: false)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result):
        return handleTranscriptionResult(&state, result: result)

      case let .transcriptionError(error):
        return handleTranscriptionError(&state, error: error)
        
      // MARK: - AI Enhancement Results
      
      case let .setEnhancingState(isEnhancing):
        state.isEnhancing = isEnhancing
        return .none
        
      case let .aiEnhancementResult(result):
        return handleAIEnhancement(&state, result: result)
        
      case let .aiEnhancementError(error):
        // Check if this is an Ollama connectivity error
        let nsError = error as NSError
        if nsError.domain == "AIEnhancementClient" && (nsError.code == -1001 || nsError.localizedDescription.contains("Ollama")) {
          print("AI Enhancement error due to Ollama connectivity: \(error)")
          return .send(.ollamaBecameUnavailable)
        } else {
          // For other errors, we need to:
          // 1. Log the error
          // 2. Disable AI enhancement status 
          // 3. Fall back to the original transcription that produced this action
          print("AI Enhancement error: \(error)")
          
          // Inform the user but avoid re-triggering AI enhancement
          state.error = "AI enhancement failed: \(error.localizedDescription). Using original transcription instead."
          
          // Finalize the flow with the raw transcription without retrying enhancement
          return .send(.aiEnhancementResult(state.pendingTranscription ?? ""))
        }
        
      case .ollamaBecameUnavailable:
        // When Ollama becomes unavailable, recheck availability and handle UI updates
        return .send(.recheckOllamaAvailability)
        
      case .recheckOllamaAvailability:
        // Recheck if Ollama is available and update UI accordingly
        return .run { send in
          let isAvailable = await aiEnhancement.isOllamaAvailable()
          if !isAvailable {
            print("[TranscriptionFeature] Ollama is not available. AI enhancement is disabled.")
            // Update state to show error to the user
            await send(.transcriptionError(NSError(
              domain: "TranscriptionFeature",
              code: -1002,
              userInfo: [NSLocalizedDescriptionKey: "Ollama is not available. AI enhancement is disabled."]
            )))
          }
        }

      // MARK: - Real-time Feedback Actions
      
      case .updateRecordingProgress:
        state.recordingProgress.update(meter: state.meter, startTime: state.recordingStartTime)
        return .none
        
      case let .updateEnhancementProgress(stage):
        state.enhancementProgress.updateStage(stage)
        return .none
        
      case .startRecordingPulse:
        state.shouldShowRecordingPulse = true
        return .run { send in
          // Create a pulsing effect during recording
          while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(1000))
            await send(.updateRecordingProgress)
            try await Task.sleep(for: .milliseconds(500))
          }
        }
        .cancellable(id: CancelID.recordingPulse)
        
      case .stopRecordingPulse:
        state.shouldShowRecordingPulse = false
        return .cancel(id: CancelID.recordingPulse)
        
      // MARK: - Streaming Transcription Actions
      
      case let .streamTranscriptionUpdate(update):
        // Only process streaming updates if we're currently streaming
        guard state.isStreamingTranscription else {
          print("[TranscriptionFeature] Ignoring stream update - streaming is not active")
          return .none
        }
        
        print("[TranscriptionFeature] Received stream update: '\(update.currentText)'")
        print("[TranscriptionFeature] Before update - state.streamingTranscription.currentText: '\(state.streamingTranscription.currentText)'")
        
        // Manually update the streaming transcription state
        state.streamingTranscription.confirmedSegments = update.confirmedSegments
        state.streamingTranscription.unconfirmedSegments = update.unconfirmedSegments
        
        // Only update currentText if the new text is not empty
        if !update.currentText.isEmpty {
          state.streamingTranscription.currentText = update.currentText
          print("[TranscriptionFeature] Updated currentText to: '\(state.streamingTranscription.currentText)'")
        } else {
          print("[TranscriptionFeature] Skipping empty currentText update")
        }
        
        // Update active state
        if !state.streamingTranscription.isActive && !state.streamingTranscription.currentText.isEmpty {
          state.streamingTranscription.isActive = true
          state.streamingTranscription.startTime = Date()
          print("[TranscriptionFeature] Activated streaming transcription")
        }
        
        print("[TranscriptionFeature] After update - state.streamingTranscription.currentText: '\(state.streamingTranscription.currentText)'")
        return .none

      // MARK: - Context Prompt Actions

      case let .setContextPrompt(prompt):
        print("[TranscriptionFeature] Setting context prompt: \"\(prompt)\"")
        state.contextPrompt = prompt
        return .none

      // MARK: - Model Prewarming Actions

      case .prewarmSelectedModel:
        let selectedModel = state.hexSettings.selectedModel

        // Only prewarm if the model is not already warm
        guard state.hexSettings.transcriptionModelWarmStatus != .warm else {
          print("[TranscriptionFeature] Model \(selectedModel) is already warm, skipping prewarming")
          return .none
        }

        // Set warming status
        state.$hexSettings.withLock { $0.transcriptionModelWarmStatus = .warming }

        return .run { send in
          do {
            // Check if the model is downloaded first
            let isDownloaded = await transcription.isModelDownloaded(selectedModel)
            guard isDownloaded else {
              print("[TranscriptionFeature] Model \(selectedModel) is not downloaded, skipping prewarming")
              await send(.prewarmCompleted(.failure(NSError(
                domain: "TranscriptionFeature",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Model \(selectedModel) is not downloaded"]
              ))))
              return
            }

            print("[TranscriptionFeature] Starting prewarming for model: \(selectedModel)")
            try await transcription.prewarmModel(selectedModel) { progress in
              Task { @MainActor in
                send(.prewarmProgress(progress.fractionCompleted))
              }
            }
            await send(.prewarmCompleted(.success(selectedModel)))
          } catch {
            print("[TranscriptionFeature] Prewarming failed for model \(selectedModel): \(error)")
            await send(.prewarmCompleted(.failure(error)))
          }
        }
        .cancellable(id: CancelID.prewarm)

      case .prewarmProgress(_):
        // Progress updates are handled silently for now
        // Could be used to update UI if needed
        return .none

      case let .prewarmCompleted(result):
        switch result {
        case let .success(model):
          print("[TranscriptionFeature] Successfully prewarmed model: \(model)")
          state.$hexSettings.withLock { $0.transcriptionModelWarmStatus = .warm }
        case let .failure(error):
          print("[TranscriptionFeature] Failed to prewarm model: \(error)")
          state.$hexSettings.withLock { $0.transcriptionModelWarmStatus = .cold }
        }
        return .none

      // MARK: - Cancel Entire Flow

      case .cancel:
        // Only cancel if we're in the middle of recording or transcribing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      // MARK: - Alert Handling

      case let .setTranscriptionFailedAlert(flag):
        state.showTranscriptionFailedAlert = flag
        return .none
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    // Create a separate actor to handle rate limiting safely in Swift 6
    actor MeterRateLimiter {
      private var lastUpdateTime = Date()
      private var lastMeter: Meter? = nil
      
      func shouldUpdate(meter: Meter) -> Bool {
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)
        
        // Always update if enough time has passed (ensures UI responsiveness)
        if timeSinceLastUpdate >= 0.05 { // Max 20 updates per second
          self.lastUpdateTime = now
          self.lastMeter = meter
          return true
        }
        // Or if there's a significant change from the last meter we actually sent
        else if let last = lastMeter {
          let averageDiff = abs(meter.averagePower - last.averagePower)
          let peakDiff = abs(meter.peakPower - last.peakPower)
          // More responsive threshold for significant changes
          let shouldUpdate = averageDiff > 0.02 || peakDiff > 0.04
          
          if shouldUpdate {
            self.lastUpdateTime = now
            self.lastMeter = meter
          }
          
          return shouldUpdate
        }
        
        self.lastUpdateTime = now
        self.lastMeter = meter
        return true // First update always passes through
      }
    }
    
    return .run { send in
      let rateLimiter = MeterRateLimiter()
      
      for await meter in await recording.observeAudioLevel() {
        // Check if we should send this update
        if await rateLimiter.shouldUpdate(meter: meter) {
          // The Effect.run captures its function as @Sendable, so we're already on an appropriate context
          // for sending actions. ComposableArchitecture handles dispatching to the main thread as needed.
            await send(.audioLevelUpdated(meter))
        }
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming key events
      keyEventMonitor.handleKeyEvent { keyEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
        if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
           hotKeyProcessor.state == .idle
        {
          Task { await send(.cancel) }
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        hotKeyProcessor.useDoubleTapOnly = hexSettings.useDoubleTapOnly

        // Process the key event
        switch hotKeyProcessor.process(keyEvent: keyEvent) {
        case .startRecording:
          let hotkeyTriggerTime = Date()
          print("🎙️ [TIMING] Hotkey triggered at: \(hotkeyTriggerTime.timeIntervalSince1970)")
          // If double-tap lock is triggered, we start recording immediately
          if hotKeyProcessor.state == .doubleTapLock {
            Task { await send(.startRecording) }
          } else {
            Task { await send(.hotKeyPressed) }
          }
          // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
          // But if useDoubleTapOnly is true, always intercept the key
          return hexSettings.useDoubleTapOnly || keyEvent.key != nil

        case .stopRecording:
          Task { await send(.hotKeyReleased) }
          return false // or `true` if you want to intercept

        case .cancel:
          Task { await send(.cancel) }
          return true

        case .none:
          // If we detect repeated same chord, maybe intercept.
          if let pressedKey = keyEvent.key,
             pressedKey == hotKeyProcessor.hotkey.key,
             keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
          {
            return true
          }
          return false
        }
      }
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    let hotkeyPressedTime = Date()
    print("🎙️ [TIMING] HotKey pressed handler triggered at: \(hotkeyPressedTime.timeIntervalSince1970)")

    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none

    // Kick off a quick microphone warm-up immediately so the hardware path is
    // already open by the time we call `recording.startRecording()` 200 ms later.
    let warmUp: Effect<Action> = .run { _ in
      await recording.warmUpAudioInput()
    }

    // We wait 200ms before actually sending `.startRecording`
    // so the user can do a quick press => do something else
    // (like a double-tap).
    let delayedStart = Effect.run { send in
      print("🎙️ [TIMING] Starting 200ms delay at: \(Date().timeIntervalSince1970)")
      try await Task.sleep(for: .milliseconds(200))
      print("🎙️ [TIMING] 200ms delay completed, sending startRecording at: \(Date().timeIntervalSince1970)")
      await send(Action.startRecording)
    }
    .cancellable(id: CancelID.delayedRecord, cancelInFlight: true)

    return .merge(maybeCancel, warmUp, delayedStart)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    if isRecording {
      // We actually stop if we're currently recording
      return .send(.stopRecording)
    } else {
      // If not recording yet, just cancel the delayed start
      return .cancel(id: CancelID.delayedRecord)
    }
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    let uiStartTime = Date()
    print("🎙️ [TIMING] UI startRecording action triggered at: \(uiStartTime.timeIntervalSince1970)")

    state.isRecording = true
    state.recordingStartTime = Date()
    state.lastAudioFeedbackTime = Date()
    state.isStreamingTranscription = true

    // Reset recording progress and streaming state
    state.recordingProgress = RecordingProgress()
    state.streamingTranscription.reset()

    // Prevent system sleep during recording
    if state.hexSettings.preventSystemSleep {
      preventSystemSleep(&state)
    }

    // Extract required values used later in the async transcription sequence
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage
    let settings = state.hexSettings
    // Values for image analysis
    let providerTypeForImage = state.hexSettings.aiProviderType
    let imageModel = providerTypeForImage == .ollama ? state.hexSettings.selectedImageModel : state.hexSettings.selectedRemoteImageModel
    let groqAPIKey = state.hexSettings.groqAPIKey
    let imageAnalysisPrompt = state.hexSettings.imageAnalysisPrompt

    print("[TranscriptionFeature] Starting recording…")

    return .merge(
      .run { _ in
        let recordingClientCallStart = Date()
        print("🎙️ [TIMING] Calling recording.startRecording() at: \(recordingClientCallStart.timeIntervalSince1970)")
        await recording.startRecording()
        let recordingClientCallEnd = Date()
        let recordingClientCallDuration = recordingClientCallEnd.timeIntervalSince(recordingClientCallStart)
        print("🎙️ [TIMING] recording.startRecording() completed in: \(String(format: "%.3f", recordingClientCallDuration))s")
      },
      .send(.startRecordingPulse),
      // Schedule screenshot capture 1s after recording starts (if enabled)
      .run { send in
        guard settings.enableScreenCapture else { return }
        try await Task.sleep(for: .seconds(1))

        guard !Task.isCancelled else { return }

        do {
          print("[TranscriptionFeature] Delayed screenshot capture starting…")
          let screenshotData = try await screenCapture.captureScreenshot()
          print("[TranscriptionFeature] Screenshot captured (\(screenshotData.count) bytes)")

          let provider = providerTypeForImage
          let modelName = imageModel
          let imagePrompt = ""

          print("[TranscriptionFeature] Image analysis provider: \(provider.displayName), model: \(modelName)")
          let context = try await aiEnhancement.analyzeImage(
            screenshotData,
            modelName,
            imagePrompt,
            provider,
            provider == .groq ? groqAPIKey : nil,
            imageAnalysisPrompt
          ) { _ in }
          print("[TranscriptionFeature] Image analysis returned context prompt: \"\(context)\"")
          await send(.setContextPrompt(context))
        } catch {
          print("[TranscriptionFeature] Failed to capture/analyse screenshot: \(error)")
        }
      }
      .cancellable(id: CancelID.screenshotCapture),
      // Start streaming transcription for real-time feedback during recording
      .run { send in
        do {
          // Create decoding options without context prompt (prompt will be applied later for the final transcription)
          let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            chunkingStrategy: .vad
          )

          print("Starting streaming transcription for real-time feedback…")

          try await transcription.startStreamTranscription(model, decodeOptions, settings) { update in
            // Forward every update to the reducer.
            Task { await send(.streamTranscriptionUpdate(update)) }
          }

          // Keep the effect alive for the lifetime of the microphone stream
          try await Task.never()
        } catch is CancellationError {
          // Normal cancellation
        } catch {
          print("Error starting streaming transcription for feedback: \(error)")
          await send(.streamTranscriptionUpdate(StreamTranscriptionUpdate(
            confirmedSegments: [],
            unconfirmedSegments: [],
            currentText: "",
            isComplete: false
          )))
        }
      }
      .cancellable(id: CancelID.streamTranscription)
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isStreamingTranscription = false // Stop streaming immediately

    // Capture *all* streaming text (confirmed + current + unconfirmed) BEFORE
    // resetting it, otherwise we might lose the beginning of the sentence if
    // Whisper started a new segment shortly before the user released the key.
    let streamingFallbackText: String = {
      let confirmed = state.streamingTranscription.confirmedSegments.map(\.text).joined(separator: " ")
      let unconfirmed = state.streamingTranscription.unconfirmedSegments.map(\.text).joined(separator: " ")
      let current = state.streamingTranscription.currentText
      return ([confirmed, current, unconfirmed].filter { !$0.isEmpty }).joined(separator: " ")
    }()

    // Reset streaming transcription state to ensure clean stop
    // This must be done early to ensure all code paths reset the streaming state
    state.streamingTranscription.reset()

    // Allow system to sleep again by releasing the power management assertion
    // Always call this, even if the setting is off, to ensure we don't leak assertions
    //  (e.g. if the setting was toggled off mid-recording)
    reallowSystemSleep(&state)

    let durationIsLongEnough: Bool = {
      guard let startTime = state.recordingStartTime else { return false }
      return Date().timeIntervalSince(startTime) > state.hexSettings.minimumKeyTime
    }()

    guard (durationIsLongEnough || state.hexSettings.hotkey.key != nil) else {
      // If the user recorded for less than minimumKeyTime, just discard
      // unless the hotkey includes a regular key, in which case, we can assume it was intentional
      print("Recording was too short, discarding")
      return .merge(
        .cancel(id: CancelID.streamTranscription),
        .cancel(id: CancelID.screenshotCapture),
        .run { _ in
          await transcription.stopStreamTranscription()
          _ = await recording.stopRecording()
        }
      )
    }

    // Otherwise, proceed to traditional transcription for final result
    state.isTranscribing = true
    state.error = nil
    
    // Keep the context prompt (may be set by delayed screenshot capture earlier)
    let contextPrompt = state.contextPrompt
    let recordingDuration: TimeInterval = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage
    let settings = state.hexSettings
    
    state.isPrewarming = true
    
    return .merge(
      .send(.stopRecordingPulse),
      // Cancel screenshot capture if it hasn't fired yet, then cancel streaming transcription
      .cancel(id: CancelID.screenshotCapture),
      .cancel(id: CancelID.streamTranscription),
      // Then stop streaming transcription synchronously before beginning offline transcription
      .run { send in
        // Ensure the real-time streaming engine is fully stopped before we
        // start an offline transcription.  If we launch them concurrently,
        // WhisperKit will cancel one of the operations which manifests as a
        // `CancellationError`.
        await transcription.stopStreamTranscription()

        // Proceed with the remainder of the stop-recording workflow.
        do {
          await soundEffect.play(.stopRecording)
          let audioURL = await recording.stopRecording()

          // Build decoding options
          // 1) baseOptions (no prompt tokens) – identical to History view
          let baseOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            chunkingStrategy: .vad
          )

          // 2) With-prefill variant that optionally contains prompt tokens
          var decodeOptionsWithPrefill = baseOptions

          var combinedPrompt = ""
          if !settings.voiceRecognitionPrompt.isEmpty {
            combinedPrompt += settings.voiceRecognitionPrompt.trimmingCharacters(in: .whitespaces)
          }
          if let prompt = contextPrompt, !prompt.isEmpty {
            combinedPrompt += " " + prompt.trimmingCharacters(in: .whitespaces)
          }

          if !combinedPrompt.isEmpty, let tokenizer = await transcription.getTokenizer() {
            decodeOptionsWithPrefill.promptTokens = tokenizer.encode(text: " " + combinedPrompt)
              .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            decodeOptionsWithPrefill.usePrefillPrompt = false
            print("[TranscriptionFeature] Applied combined prompt with \(decodeOptionsWithPrefill.promptTokens?.count ?? 0) tokens: '\(combinedPrompt)'")
          }

          // Transcription WITH prefill prompt
          print("Transcribing recorded audio WITH prefill prompt…")
          let resultWithPrefill = try await transcription.transcribe(
            audioURL,
            model,
            decodeOptionsWithPrefill,
            settings
          ) { _ in }

          print("Result WITH prefill prompt: \"\(resultWithPrefill)\"")

          var resultWithoutPrefill = ""
          // Transcription WITHOUT prefill prompt
          if resultWithPrefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("Result WITH prefill prompt is empty, transcribing WITHOUT prefill prompt…")
            let decodeOptionsNoPrefill = baseOptions

            // 1. Transcription WITHOUT prefill prompt (with one-shot retry if empty)
            print("Transcribing recorded audio WITHOUT prefill prompt…")
            resultWithoutPrefill = try await transcription.transcribe(
              audioURL,
              model,
              decodeOptionsNoPrefill,
              settings
            ) { _ in }

            print("Initial result WITHOUT prefill prompt: \"\(resultWithoutPrefill)\"")

            if resultWithoutPrefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                recordingDuration > 3 {
              print("[TranscriptionFeature] Empty initial result for >3 s recording – retrying once after 500 ms…")
              try await Task.sleep(for: .milliseconds(1000))

              let retryResultNP = try await transcription.transcribe(
                audioURL,
                model,
                decodeOptionsNoPrefill,
                settings
              ) { _ in }

              print("[TranscriptionFeature] Retry result WITHOUT prefill: \"\(retryResultNP)\"")

              if !retryResultNP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resultWithoutPrefill = retryResultNP
              }
              print("Final result WITHOUT prefill prompt (after optional retry): \"\(resultWithoutPrefill)\"")
            }
          }

          // Decide preferred result (prefer prefill variant if non-empty)
          let preferredResult: String
          if !resultWithPrefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preferredResult = resultWithPrefill
          } else if !resultWithoutPrefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preferredResult = resultWithoutPrefill
          } else {
            preferredResult = ""
          }

          // Fallback to streaming text if both results are empty
          let finalResult: String
          if preferredResult.isEmpty && !streamingFallbackText.isEmpty {
            print("[TranscriptionFeature] Both transcription variants are empty, using streaming fallback: '\(streamingFallbackText)'")
            finalResult = streamingFallbackText
          } else {
            finalResult = preferredResult
          }

          print("Chosen transcription result: \"\(finalResult)\"")
          TokLogger.log("Final transcription: \(finalResult)")
          await send(.transcriptionResult(finalResult))
        } catch {
          print("Error transcribing audio: \(error)")
          await send(.transcriptionError(error))
        }
      }
      .cancellable(id: CancelID.transcription)
    )
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String
  ) -> Effect<Action> {
    // First check if we should use AI enhancement
    if state.hexSettings.useAIEnhancement {
      // Keep state.isTranscribing = true since we're still processing
      
      // Store the original transcription for error handling/fallback
      state.pendingTranscription = result
      
      // Extract values to avoid capturing inout parameter
      let providerType = state.hexSettings.aiProviderType
      let selectedAIModel = state.hexSettings.selectedAIModel
      let selectedRemoteModel = state.hexSettings.selectedRemoteModel
      let promptText = state.hexSettings.aiEnhancementPrompt
      let temperature = state.hexSettings.aiEnhancementTemperature
      let groqAPIKey = state.hexSettings.groqAPIKey
      let contextPrompt = state.contextPrompt
      
      return enhanceWithAI(
        result: result,
        providerType: providerType,
        selectedAIModel: selectedAIModel,
        selectedRemoteModel: selectedRemoteModel,
        promptText: promptText,
        temperature: temperature,
        groqAPIKey: groqAPIKey,
        contextPrompt: contextPrompt
      )
    } else {
      state.isTranscribing = false
      state.isPrewarming = false

      // If empty text, nothing else to do
      guard !result.isEmpty else {
        return .none
      }

      // Compute how long we recorded
      let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

      // Continue with storing the final result in the background
      return finalizeRecordingAndStoreTranscript(
        result: result,
        duration: duration,
        transcriptionHistory: state.$transcriptionHistory
      )
    }
  }
  
  // MARK: - AI Enhancement Handlers
  
  // Use AI to enhance the transcription result
  private func enhanceWithAI(
    result: String,
    providerType: AIProviderType,
    selectedAIModel: String,
    selectedRemoteModel: String,
    promptText: String,
    temperature: Double,
    groqAPIKey: String,
    contextPrompt: String?
  ) -> Effect<Action> {
    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .send(.aiEnhancementResult(result)) // Just pass through empty text
    }
    
    let options = EnhancementOptions(
      prompt: promptText,
      temperature: temperature,
      context: contextPrompt
    )
    
    // Determine the actual model to use based on provider
    let model = providerType == .ollama ? selectedAIModel : selectedRemoteModel
    let apiKey = providerType == .groq ? groqAPIKey : nil
    
    print("[TranscriptionFeature] Starting AI enhancement with \(providerType.displayName), model: \(model)")
    
    // We need to use .send to set the enhancing state through the proper action
    return .merge(
      // First update the state to indicate enhancement is starting
      .send(.setEnhancingState(true)),
      .send(.updateEnhancementProgress(.connecting)),
      
      // Play enhancement start sound
      .run { _ in
        await soundEffect.play(.enhancementStart)
      },
      
      // Then run the enhancement
      .run { send in
        do {
          print("[TranscriptionFeature] Calling aiEnhancement.enhance()")
          
          // Update progress to processing
          await send(.updateEnhancementProgress(.processing))
          
          // Access the raw value directly to avoid argument label issues
          let enhanceMethod = aiEnhancement.enhance
          let enhancedText = try await enhanceMethod(result, model, options, providerType, apiKey) { progress in
            // Optional: Could update UI with progress information here if needed
          }
          
          // Update progress to finalizing
          await send(.updateEnhancementProgress(.finalizing))
          
          print("[TranscriptionFeature] AI enhancement succeeded")
          await send(.aiEnhancementResult(enhancedText))
        } catch {
          print("[TranscriptionFeature] Error enhancing text with AI: \(error)")
          // Update progress to error state
          await send(.updateEnhancementProgress(.error(error.localizedDescription)))
          // Properly handle the error through the action system
          await send(.aiEnhancementError(error))
        }
      }
    )
    // Don't make this cancellable to avoid premature cancellation
    // This may have been causing the issue with the enhancement being cancelled
  }
  
  // Handle the AI enhancement result
  private func handleAIEnhancement(
    _ state: inout State,
    result: String
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.isEnhancing = false  // Reset the enhancing state
    state.pendingTranscription = nil  // Clear the pending transcription since enhancement succeeded

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .merge(
        .send(.updateEnhancementProgress(.completed)),
        .send(.updateEnhancementProgress(.idle))
      )
    }

    // Compute how long we recorded
    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

    // Continue with storing the final result in the background
    return .merge(
      .send(.updateEnhancementProgress(.completed)),
      
      // Play enhancement complete sound
      .run { _ in
        await soundEffect.play(.enhancementComplete)
      },
      
      finalizeRecordingAndStoreTranscript(
        result: result,
        duration: duration,
        transcriptionHistory: state.$transcriptionHistory
      ),
      .run { send in
        // Clear progress after a short delay
        try await Task.sleep(for: .milliseconds(1000))
        await send(.updateEnhancementProgress(.idle))
      }
    )
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription

    return .run { _ in
      await soundEffect.play(.cancel)
    }
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) -> Effect<Action> {
    .run { send in
      // Detect potential transcription failure (long recording but short/empty text)
      let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
      if duration >= 10 && trimmed.count < 10 {
        await send(.setTranscriptionFailedAlert(true))
      }

      do {
        let originalURL = await recording.stopRecording()

        // Move the file to a permanent location
        let fm = FileManager.default
        let supportDir = try fm.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )
        let ourAppFolder = supportDir.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
        let recordingsFolder = ourAppFolder.appendingPathComponent("Recordings", isDirectory: true)
        try fm.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)

        // Create a unique file name
        let filename = "\(Date().timeIntervalSince1970).wav"
        let finalURL = recordingsFolder.appendingPathComponent(filename)

        // Move temp => final
        try fm.moveItem(at: originalURL, to: finalURL)

        // Build a transcript object
        let transcript = Transcript(
          timestamp: Date(),
          text: result,
          audioPath: finalURL,
          duration: duration
        )

        // Append to the in-memory shared history
        transcriptionHistory.withLock {
          $0.history.insert(transcript, at: 0)
        }

        // Paste text (and copy if enabled via pasteWithClipboard)
        await pasteboard.paste(result)
        await soundEffect.play(.pasteTranscript)
      } catch {
        await send(.transcriptionError(error))
      }
    }
  }
}

// MARK: - Cancel Handler

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.isEnhancing = false
    state.shouldShowRecordingPulse = false
    state.isStreamingTranscription = false
    
    // Reset progress states
    state.recordingProgress = RecordingProgress()
    state.enhancementProgress.updateStage(.idle)
    state.streamingTranscription.reset()

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.delayedRecord),
      .cancel(id: CancelID.recordingPulse),
      .cancel(id: CancelID.recordingFeedback),
      .cancel(id: CancelID.enhancementFeedback),
      .cancel(id: CancelID.streamTranscription),
      .cancel(id: CancelID.screenshotCapture),
      // Stop streaming transcription after cancelling the effect
      .run { _ in
        await transcription.stopStreamTranscription()
      },
      // Don't cancel AI enhancement as it might cause issues with Ollama
      // This creates a UI inconsistency where the UI shows cancellation
      // but enhancement continues in background. We intentionally allow this
      // to prevent issues with Ollama's streaming API and ensure stability.
      // TODO: Consider implementing a safer cancellation approach or state tracking
      // to properly ignore late results after cancellation.
      // .cancel(id: CancelID.aiEnhancement),
      .run { _ in
        await soundEffect.play(.cancel)
      }
    )
  }
}

// MARK: - System Sleep Prevention

private extension TranscriptionFeature {
  func preventSystemSleep(_ state: inout State) {
    // Prevent system sleep during recording
    let reasonForActivity = "Tok Voice Recording" as CFString
    var assertionID: IOPMAssertionID = 0
    let success = IOPMAssertionCreateWithName(
      kIOPMAssertionTypeNoDisplaySleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reasonForActivity,
      &assertionID
    )
    if success == kIOReturnSuccess {
      state.assertionID = assertionID
    }
  }

  func reallowSystemSleep(_ state: inout State) {
    if let assertionID = state.assertionID {
      let releaseSuccess = IOPMAssertionRelease(assertionID)
      if releaseSuccess == kIOReturnSuccess {
        state.assertionID = nil
      }
    }
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>

  var status: TranscriptionIndicatorView.Status {
    let computedStatus: TranscriptionIndicatorView.Status
    
    if store.isEnhancing {
      computedStatus = .enhancing 
    } else if store.isTranscribing {
      computedStatus = .transcribing
    } else if store.isRecording {
      // Show streaming transcription status during recording if streaming is active
      // We don't require currentText to be non-empty since we want to show the streaming UI
      // even during temporary empty states between transcription updates
      computedStatus = store.isStreamingTranscription ? .streamingTranscription : .recording
    } else if store.isPrewarming {
      computedStatus = .prewarming
    } else {
      computedStatus = .hidden
    }
    
    // Debug logging to understand status and data flow
    print("[TranscriptionView] Status: \(computedStatus)")
    print("[TranscriptionView] isRecording: \(store.isRecording), isStreamingTranscription: \(store.isStreamingTranscription)")
    print("[TranscriptionView] streamingTranscription.currentText: '\(store.streamingTranscription.currentText)'")
    print("[TranscriptionView] streamingTranscription.isActive: \(store.streamingTranscription.isActive)")
    
    return computedStatus
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      meter: store.meter,
      recordingProgress: store.isRecording ? store.recordingProgress : nil,
      enhancementProgress: store.isEnhancing ? store.enhancementProgress : nil,
      showRecordingPulse: store.shouldShowRecordingPulse,
      streamingTranscription: store.isStreamingTranscription ? store.streamingTranscription : nil
    )
    .task {
      await store.send(.task).finish()
    }
    // Alert for potential failed transcription
    .alert(
      "Transcription May Have Failed",
      isPresented: Binding(
        get: { store.showTranscriptionFailedAlert },
        set: { newValue in
          if !newValue {
            store.send(.setTranscriptionFailedAlert(false))
          }
        }
      )
    ) {
      Button("OK", role: .cancel) {
        store.send(.setTranscriptionFailedAlert(false))
      }
    } message: {
      Text("The recording was long but the resulting transcription appears to be empty or incomplete. You can retry the transcription from the History tab in Settings.")
    }
  }
}
