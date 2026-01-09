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
import Carbon
import Sauce

// MARK: - Notification Names for Edit Overlay

extension Notification.Name {
    static let editOverlayConfirmed = Notification.Name("editOverlayConfirmed")
    static let editOverlayCancelled = Notification.Name("editOverlayCancelled")
    static let editOverlayTextChanged = Notification.Name("editOverlayTextChanged")
    // Hotkey events from overlay (when overlay has keyboard focus)
    static let overlayHotkeyPressed = Notification.Name("overlayHotkeyPressed")
    static let overlayHotkeyReleased = Notification.Name("overlayHotkeyReleased")
}

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
    
    // Buffer rule: only accept the new currentText if it is
    // 1) non-empty AND
    // 2) at least as long as the current text.
    // This prevents the UI from flickering when Whisper temporarily
    // emits shorter (or empty) partial hypotheses before extending them again.
    if !update.currentText.isEmpty && update.currentText.count >= currentText.count {
      currentText = update.currentText
      print("[StreamingTranscription] Updated currentText to: '\(currentText)'")
    } else {
      print("[StreamingTranscription] Skipping currentText update (buffer rule)")
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
  struct State: Equatable {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var isEnhancing: Bool = false // Add this to track when AI enhancement is active
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var assertionID: IOPMAssertionID?
    var pendingTranscription: String? // Store original transcription for fallback
    /// Stores the combined real-time (streaming) transcription so it can be provided to AI enhancement later.
    var realTimeTranscription: String? = nil
    
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

    // Track if edit overlay is currently visible (allows appending recordings)
    var isOverlayVisible: Bool = false

    @Shared(.hexSettings) var hexSettings: HexSettings
    // DISABLED: History功能暫時停用
    // @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory

    // Manual Equatable conformance – we only care about fields that drive the
    // status-bar Pac-Man animation to avoid unnecessary view updates.
    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.isRecording == rhs.isRecording && lhs.meter == rhs.meter
    }
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

    // Edit Overlay actions
    case showEditOverlay(String)
    case appendToOverlay(String)
    case editOverlayConfirmed(String)
    case editOverlayCancelled
    case editOverlayTextChanged(original: String, edited: String)
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
    case hotKeyWatchdog
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.aiEnhancement) var aiEnhancement
  @Dependency(\.screenCapture) var screenCapture
  @Dependency(\.overlayClient) var overlayClient

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
        // Ignore hotkey presses if we're already recording
        // But allow new recording if overlay is visible (for appending text)
        print("🔑 [TCA] hotKeyPressed - isRecording: \(state.isRecording), isTranscribing: \(state.isTranscribing), isOverlayVisible: \(state.isOverlayVisible)")
        debugLog("[TCA] hotKeyPressed - isRecording: \(state.isRecording), isTranscribing: \(state.isTranscribing), isOverlayVisible: \(state.isOverlayVisible)")

        // If already recording, ignore
        guard !state.isRecording else {
          print("🔑 [TCA] Hotkey press IGNORED - recording already in progress")
          return .none
        }

        // If transcribing but overlay is NOT visible, ignore (still processing)
        // If overlay IS visible, allow new recording for appending
        if state.isTranscribing && !state.isOverlayVisible {
          print("🔑 [TCA] Hotkey press IGNORED - transcription in progress, overlay not visible")
          return .none
        }

        print("🔑 [TCA] Hotkey press ACCEPTED - proceeding with recording (overlay visible: \(state.isOverlayVisible))")
        // Proceed with recording - if overlay is visible, result will be appended
        // Skip caret capture if overlay is already visible (no need to recapture position)
        return handleHotKeyPressed(isTranscribing: false, skipCaretCapture: state.isOverlayVisible)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        print("🔥 [DEBUG] Action.startRecording received - starting recording flow")
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
        // Immediately update the recording progress so the UI shows a non-zero duration as soon as possible.
        return .merge(
          .send(.updateRecordingProgress),
          .run { send in
            // Continuously update the progress every 500 ms while recording.
            while !Task.isCancelled {
              try await Task.sleep(for: .milliseconds(500))
              await send(.updateRecordingProgress)
            }
          }
          .cancellable(id: CancelID.recordingPulse)
        )
        
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
        
        // Delegate buffering logic to the helper on the StreamingTranscription struct
        state.streamingTranscription.updateFromStream(update)
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

      // MARK: - Edit Overlay Actions

      case let .showEditOverlay(text):
        // Show the edit overlay with the transcribed text
        // Reset transcribing state so new recordings can be started
        state.isTranscribing = false
        state.isOverlayVisible = true
        print("📝 [TCA] showEditOverlay - setting isOverlayVisible=true, isTranscribing=false")
        debugLog("[TCA] showEditOverlay - setting isOverlayVisible=true, isTranscribing=false")
        return .run { _ in
          // Set up callbacks before showing
          await overlayClient.setOnConfirm { confirmedText in
            Task { @MainActor in
              // This will be handled by the TCA store through a different mechanism
              // For now, we use a notification-based approach
              NotificationCenter.default.post(
                name: .editOverlayConfirmed,
                object: nil,
                userInfo: ["text": confirmedText]
              )
            }
          }
          await overlayClient.setOnCancel {
            Task { @MainActor in
              NotificationCenter.default.post(name: .editOverlayCancelled, object: nil)
            }
          }
          await overlayClient.setOnTextChanged { original, edited in
            Task { @MainActor in
              NotificationCenter.default.post(
                name: .editOverlayTextChanged,
                object: nil,
                userInfo: ["original": original, "edited": edited]
              )
            }
          }
          await overlayClient.show(text)
        }

      case let .editOverlayConfirmed(text):
        // User confirmed the edited text - paste it
        // Reset ALL states to allow new recording (same as handleCancel)
        debugLog("[TCA] editOverlayConfirmed BEFORE - isRecording: \(state.isRecording), isTranscribing: \(state.isTranscribing), isOverlayVisible: \(state.isOverlayVisible)")
        state.isTranscribing = false
        state.isRecording = false
        state.isPrewarming = false
        state.isEnhancing = false
        state.shouldShowRecordingPulse = false
        state.isStreamingTranscription = false
        state.isOverlayVisible = false
        state.meter = .init(averagePower: 0, peakPower: 0)
        state.recordingProgress = RecordingProgress()
        state.enhancementProgress.updateStage(.idle)
        state.streamingTranscription.reset()
        state.realTimeTranscription = nil
        debugLog("[TCA] editOverlayConfirmed AFTER - isRecording: \(state.isRecording), isTranscribing: \(state.isTranscribing), isOverlayVisible: \(state.isOverlayVisible)")

        return .merge(
          .cancel(id: CancelID.transcription),
          .cancel(id: CancelID.delayedRecord),
          .cancel(id: CancelID.recordingPulse),
          .cancel(id: CancelID.recordingFeedback),
          .cancel(id: CancelID.enhancementFeedback),
          .cancel(id: CancelID.streamTranscription),
          .cancel(id: CancelID.screenshotCapture),
          .cancel(id: CancelID.hotKeyWatchdog),
          .run { _ in
            await transcription.stopStreamTranscription()
          },
          .run { _ in
            await pasteboard.paste(text)
            await soundEffect.play(.pasteTranscript)
          }
        )

      case .editOverlayCancelled:
        // User cancelled - reset ALL states to allow new recording (same as handleCancel)
        debugLog("[TCA] editOverlayCancelled - resetting all states")
        state.isTranscribing = false
        state.isRecording = false
        state.isPrewarming = false
        state.isEnhancing = false
        state.shouldShowRecordingPulse = false
        state.isStreamingTranscription = false
        state.isOverlayVisible = false
        state.meter = .init(averagePower: 0, peakPower: 0)
        state.recordingProgress = RecordingProgress()
        state.enhancementProgress.updateStage(.idle)
        state.streamingTranscription.reset()
        state.realTimeTranscription = nil

        return .merge(
          .cancel(id: CancelID.transcription),
          .cancel(id: CancelID.delayedRecord),
          .cancel(id: CancelID.recordingPulse),
          .cancel(id: CancelID.recordingFeedback),
          .cancel(id: CancelID.enhancementFeedback),
          .cancel(id: CancelID.streamTranscription),
          .cancel(id: CancelID.screenshotCapture),
          .cancel(id: CancelID.hotKeyWatchdog),
          .run { _ in
            await transcription.stopStreamTranscription()
          },
          .run { _ in
            await soundEffect.play(.cancel)
          }
        )

      case let .appendToOverlay(text):
        // Append new transcription to existing overlay text
        debugLog("[TCA] appendToOverlay - appending text: \(text)")
        // Reset transcribing state so user can record again
        state.isTranscribing = false
        return .run { _ in
          await overlayClient.appendText(text)
        }

      case let .editOverlayTextChanged(original, edited):
        // Track the correction for auto-learning
        guard state.hexSettings.autoLearnFromCorrections else {
          return .none
        }
        return .run { _ in
          // Use CorrectionHistory to track and potentially auto-learn
          let history = CorrectionHistory.shared
          let diffTracker = DiffTracker()
          let corrections = diffTracker.findCorrections(original: original, edited: edited)

          for correction in corrections {
            // This will automatically trigger auto-learning via notifications
            // when correction count reaches threshold
            history.recordCorrection(original: correction.original, edited: correction.corrected)
          }
        }
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
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings
      
      // Initialize with current user settings instead of hardcoded Option key
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: hexSettings.hotkey)
      var lastTriggerTime: Date = .distantPast
      let minimumTriggerInterval: TimeInterval = 0.1 // 100ms minimum between triggers

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

        // Add debouncing to prevent rapid fire triggers
        let now = Date()

        // Process the key event
        switch hotKeyProcessor.process(keyEvent: keyEvent) {
        case .startRecording:
          // Additional safety check: prevent triggers that are too close together
          guard now.timeIntervalSince(lastTriggerTime) >= minimumTriggerInterval else {
            print("🔥 [DEBUG] Hotkey trigger blocked - too soon after last trigger")
            return true
          }
          
          // TODO: Re-enable system state check after debugging
          // Verify hotkey is actually pressed using system state
          // guard Self.isHotKeyCurrentlyPressed(hexSettings.hotkey) else {
          //   print("🔥 [DEBUG] Hotkey trigger blocked - system state check failed")
          //   return true
          // }
          
          lastTriggerTime = now
          let hotkeyTriggerTime = Date()
          print("🔥 [DEBUG] HotKeyProcessor triggered .startRecording at: \(hotkeyTriggerTime.timeIntervalSince1970)")
          print("🔥 [DEBUG] Current hotkey config: key=\(hexSettings.hotkey.key?.rawValue ?? "nil"), modifiers=\(hexSettings.hotkey.modifiers)")
          print("🔥 [DEBUG] KeyEvent that triggered: key=\(keyEvent.key?.rawValue ?? "nil"), modifiers=\(keyEvent.modifiers)")
          print("🔥 [DEBUG] HotKeyProcessor state: \(hotKeyProcessor.state)")
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
          Task { await send(TranscriptionFeature.Action.hotKeyReleased) }
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
  func handleHotKeyPressed(isTranscribing: Bool, skipCaretCapture: Bool = false) -> Effect<Action> {
    let hotkeyPressedTime = Date()
    print("🎙️ [TIMING] HotKey pressed handler triggered at: \(hotkeyPressedTime.timeIntervalSince1970), skipCaretCapture: \(skipCaretCapture)")

    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none

    // Capture caret position IMMEDIATELY before anything else changes focus
    // This is critical for showing the overlay at the correct position later
    // Skip this if overlay is already visible (we're appending, position already known)
    let capturePosition: Effect<Action>
    if skipCaretCapture {
      capturePosition = .none
    } else {
      capturePosition = .run { _ in
        await overlayClient.captureCaretPosition()
      }
    }

    // Kick off a quick microphone warm-up immediately so the hardware path is
    // already open by the time we call `recording.startRecording()` 200 ms later.
    let warmUp: Effect<Action> = .run { _ in
      await recording.warmUpAudioInput()
    }

    // We wait 200ms before actually sending `.startRecording`
    // so the user can do a quick press => do something else
    // (like a double-tap).
    // When appending (overlay visible), reduce delay to 100ms for faster response
    let delayMs = skipCaretCapture ? 100 : 200
    let delayedStart = Effect.run { send in
      print("🎙️ [TIMING] Starting \(delayMs)ms delay at: \(Date().timeIntervalSince1970)")
      try await Task.sleep(for: .milliseconds(delayMs))
      print("🎙️ [TIMING] \(delayMs)ms delay completed, sending startRecording at: \(Date().timeIntervalSince1970)")
      await send(Action.startRecording)
    }
    .cancellable(id: CancelID.delayedRecord, cancelInFlight: true)

    // Watchdog: while in press-and-hold, periodically verify the hotkey is still held.
    let watchdog = Effect.run { send in
      @Shared(.hexSettings) var settings: HexSettings

      while !Task.isCancelled {
        try await Task.sleep(for: .milliseconds(50))

        let hotkey = settings.hotkey
        if !Self.isHotKeyCurrentlyPressed(hotkey) {
          await send(TranscriptionFeature.Action.hotKeyReleased)
          break
        }
      }
    }
    .cancellable(id: CancelID.hotKeyWatchdog, cancelInFlight: true)

    return .merge(capturePosition, maybeCancel, warmUp, delayedStart, watchdog)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    let cancelWatchdog: Effect<Action> = .cancel(id: CancelID.hotKeyWatchdog)

    if isRecording {
      // We actually stop if we're currently recording
      return .merge(.send(.stopRecording), cancelWatchdog)
    } else {
      // If not recording yet, just cancel the delayed start
      return .merge(.cancel(id: CancelID.delayedRecord), cancelWatchdog)
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
      // Schedule screenshot capture 1s after recording starts (if enabled and has permission)
      .run { send in
        guard settings.enableScreenCapture else { return }

        // Check if we have screen capture permission before attempting capture
        // CGPreflightScreenCaptureAccess() checks without triggering a permission dialog
        guard CGPreflightScreenCaptureAccess() else {
          print("[TranscriptionFeature] Screen capture permission not granted, skipping screenshot")
          return
        }

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
          // Create decoding options with custom word prompts for streaming
          // Normalize Chinese language codes for WhisperKit
          let normalizedLanguage = TranscriptionFeature.normalizeLanguageForWhisper(language)
          var decodeOptions = DecodingOptions(
            language: normalizedLanguage,
            detectLanguage: normalizedLanguage == nil,
            chunkingStrategy: .vad
          )

          // Add custom word prompt entries (提示詞) for streaming transcription
          // promptTokens are prepended to prefill tokens to bias transcription
          let customWordDict = getCachedCustomWordDictionary()
          let customWordPrompt = customWordDict.promptText
          if !customWordPrompt.isEmpty, let tokenizer = await transcription.getTokenizer() {
            let promptTokens = tokenizer.encode(text: " " + customWordPrompt)
              .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            decodeOptions.promptTokens = promptTokens
            // Keep usePrefillPrompt as default (true) - promptTokens will be prepended
            print("[TranscriptionFeature] Streaming: Added \(customWordDict.enabledPromptEntries.count) custom word prompts (\(promptTokens.count) tokens): '\(customWordPrompt)'")
          }

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
    // Reset meter to baseline values so UI (e.g., Pac-Man icon) returns to its resting state.
    state.meter = .init(averagePower: 0, peakPower: 0)

    // Capture *all* streaming text (confirmed + current + unconfirmed) BEFORE
    // resetting it, otherwise we might lose the beginning of the sentence if
    // Whisper started a new segment shortly before the user released the key.
    let streamingFallbackText: String = {
      let confirmed = state.streamingTranscription.confirmedSegments.map(\.text).joined(separator: " ")
      let unconfirmed = state.streamingTranscription.unconfirmedSegments.map(\.text).joined(separator: " ")
      let current = state.streamingTranscription.currentText
      return ([confirmed, current, unconfirmed].filter { !$0.isEmpty }).joined(separator: " ")
    }()

    // Persist the real-time transcription so we can feed it into the AI enhancement later.
    state.realTimeTranscription = streamingFallbackText

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
          // Normalize Chinese language codes for WhisperKit
          let normalizedLanguage = TranscriptionFeature.normalizeLanguageForWhisper(language)
          let baseOptions = DecodingOptions(
            language: normalizedLanguage,
            detectLanguage: normalizedLanguage == nil,
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

          // Add custom word prompt entries (提示詞) to bias Whisper transcription
          let customWordDict = getCachedCustomWordDictionary()
          let customWordPrompt = customWordDict.promptText
          if !customWordPrompt.isEmpty {
            combinedPrompt += " " + customWordPrompt
            print("[TranscriptionFeature] Added \(customWordDict.enabledPromptEntries.count) custom word prompts")
          }

          if !combinedPrompt.isEmpty, let tokenizer = await transcription.getTokenizer() {
            decodeOptionsWithPrefill.promptTokens = tokenizer.encode(text: " " + combinedPrompt)
              .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            // 保持 usePrefillPrompt = true（預設值），讓 language/task tokens 正常預填充
            // promptTokens 會作為「前文上下文」與預填充 tokens 一起使用，引導 Whisper 辨識特定詞彙
            print("[TranscriptionFeature] Applied combined prompt with \(decodeOptionsWithPrefill.promptTokens?.count ?? 0) tokens: '\(combinedPrompt.prefix(100))...'")
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
          var preferredResult: String
          if !resultWithPrefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preferredResult = resultWithPrefill
          } else if !resultWithoutPrefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preferredResult = resultWithoutPrefill
          } else {
            preferredResult = ""
          }

          // Remove common hallucination phrases from preferredResult
          // Check if streamingFallbackText ends with hallucination phrases
          let fallbackLower = streamingFallbackText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          let hasHallucinationSuffix = fallbackLower.hasSuffix("thank you.") || fallbackLower.hasSuffix("thank you") ||
                                       fallbackLower.hasSuffix("謝謝") || fallbackLower.hasSuffix("謝謝大家")

          if !hasHallucinationSuffix {
            // Remove English hallucinations
            preferredResult = preferredResult.replacingOccurrences(of: "Thank you.", with: "", options: .caseInsensitive)
            preferredResult = preferredResult.replacingOccurrences(of: "Thank you", with: "", options: .caseInsensitive)
            
            // Remove Chinese hallucinations
            preferredResult = preferredResult.replacingOccurrences(of: "謝謝大家", with: "", options: .caseInsensitive)
            preferredResult = preferredResult.replacingOccurrences(of: "謝謝", with: "", options: .caseInsensitive)
            preferredResult = preferredResult.replacingOccurrences(of: "感謝大家", with: "", options: .caseInsensitive)
            preferredResult = preferredResult.replacingOccurrences(of: "感謝", with: "", options: .caseInsensitive)
          }

          let rawFinalResult: String
          if preferredResult.isEmpty && 
             !streamingFallbackText.isEmpty && 
             settings.enableStreamingFallback &&
             streamingFallbackText.trimmingCharacters(in: .whitespacesAndNewlines).count >= settings.minimumFallbackLength {
            
            // Additional check: filter out likely hallucination text
            if !Self.isLikelyHallucinationText(streamingFallbackText) {
              print("[TranscriptionFeature] Both transcription variants are empty, using streaming fallback: '\(streamingFallbackText)'")
              rawFinalResult = streamingFallbackText
            } else {
              print("[TranscriptionFeature] Streaming fallback rejected as likely hallucination: '\(streamingFallbackText)'")
              rawFinalResult = ""
            }
          } else {
            rawFinalResult = preferredResult
          }

          // Clean Whisper tokens from the final result
          var finalResult = transcription.cleanWhisperTokens(rawFinalResult)

          // Smart hallucination filtering: Only filter if the result is likely pure hallucination
          let trimmedResult = finalResult.trimmingCharacters(in: .whitespacesAndNewlines)

          // Apply filtering for hallucination patterns:
          // - Short text (<=15 chars) matching common patterns
          // - Any length text matching known long hallucination patterns (e.g., YouTube/Bilibili phrases)
          if Self.isLikelyHallucinationText(trimmedResult) {
            print("[TranscriptionFeature] Filtering out hallucination text: '\(trimmedResult)'")
            finalResult = ""
          } else {
            finalResult = trimmedResult
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
    // Ignore empty (or whitespace-only) transcriptions altogether
    let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedResult.isEmpty else {
      state.isTranscribing = false
      state.isPrewarming = false
      state.realTimeTranscription = nil
      return .none
    }
    // First check if we should use AI enhancement
    if state.hexSettings.useAIEnhancement {
      // Keep state.isTranscribing = true since we're still processing
      
      // Store the original transcription for error handling/fallback
      state.pendingTranscription = trimmedResult
      
      // Extract values to avoid capturing inout parameter
      let providerType = state.hexSettings.aiProviderType
      let selectedAIModel = state.hexSettings.selectedAIModel
      let selectedRemoteModel = state.hexSettings.selectedRemoteModel
      let promptText = state.hexSettings.aiEnhancementPrompt
      let temperature = state.hexSettings.aiEnhancementTemperature
      let groqAPIKey = state.hexSettings.groqAPIKey
      let baseContextPrompt = state.contextPrompt
      let realTimeText = state.realTimeTranscription

      // Combine any existing context with the real-time transcription so the AI model
      // can reference both when enhancing the final text.
      var combinedContextComponents: [String] = []
      if let ctx = baseContextPrompt, !ctx.isEmpty {
        combinedContextComponents.append(ctx)
      }
      if let rt = realTimeText, !rt.isEmpty {
        combinedContextComponents.append("REAL_TIME_TRANSCRIPTION:\n" + rt)
      }
      let combinedContext: String? = combinedContextComponents.isEmpty ? nil : combinedContextComponents.joined(separator: "\n\n")

      // Add an instruction so the model respects the language of the real-time transcription.
      var enhancedPrompt = promptText
      let languageRule = "If the REAL_TIME_TRANSCRIPTION appears to be in a language other than English, your final improved text must be in that same language and must NOT be translated to English."
      if enhancedPrompt.isEmpty {
        enhancedPrompt = languageRule
      } else {
        enhancedPrompt += "\n\n" + languageRule
      }

      print("[TranscriptionFeature] Enhanced prompt: \(enhancedPrompt)")

      return enhanceWithAI(
        result: trimmedResult,
        providerType: providerType,
        selectedAIModel: selectedAIModel,
        selectedRemoteModel: selectedRemoteModel,
        promptText: enhancedPrompt,
        temperature: temperature,
        groqAPIKey: groqAPIKey,
        contextPrompt: combinedContext
      )
    } else {
      // If empty text, nothing else to do
      guard !trimmedResult.isEmpty else {
        state.isTranscribing = false
        state.isPrewarming = false
        state.realTimeTranscription = nil
        return .none
      }

      // Compute how long we recorded
      let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

      // DISABLED: History功能暫時停用
      // return finalizeRecordingAndStoreTranscript(
      //   result: trimmedResult,
      //   duration: duration,
      //   transcriptionHistory: state.$transcriptionHistory
      // )

      // Check if edit overlay is enabled
      if state.hexSettings.useEditOverlay {
        // If overlay is already visible, append text instead of replacing
        if state.isOverlayVisible {
          debugLog("[TCA] handleTranscriptionResult - overlay visible, appending text")
          return .send(.appendToOverlay(trimmedResult))
        }
        // Show edit overlay for user to review/edit before pasting
        // Keep transcribing state until overlay is dismissed
        return .send(.showEditOverlay(trimmedResult))
      } else {
        // Direct paste without overlay
        state.isTranscribing = false
        state.isPrewarming = false
        state.realTimeTranscription = nil
        return .run { _ in
          await pasteboard.paste(trimmedResult)
          await soundEffect.play(.pasteTranscript)
        }
      }
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
    // Trim whitespace so we don't send blank requests to the AI service
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)

    // If empty text, nothing else to do
    guard !trimmed.isEmpty else {
      return .send(.aiEnhancementResult(trimmed)) // Just pass through empty text
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
          let enhancedText = try await enhanceMethod(trimmed, model, options, providerType, apiKey) { progress in
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
    state.realTimeTranscription = nil  // Clear stored real-time transcription

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .merge(
        .send(.updateEnhancementProgress(.completed)),
        .send(.updateEnhancementProgress(.idle))
      )
    }

    // Compute how long we recorded
    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

    // DISABLED: History功能暫時停用
    // finalizeRecordingAndStoreTranscript(
    //   result: result,
    //   duration: duration,
    //   transcriptionHistory: state.$transcriptionHistory
    // ),

    // Check if edit overlay is enabled
    if state.hexSettings.useEditOverlay {
      // If overlay is already visible, append text instead of replacing
      if state.isOverlayVisible {
        debugLog("[TCA] handleAIEnhancement - overlay visible, appending text")
        return .merge(
          .send(.updateEnhancementProgress(.completed)),
          .run { _ in
            await soundEffect.play(.enhancementComplete)
          },
          .send(.appendToOverlay(result)),
          .run { send in
            // Clear progress after a short delay
            try await Task.sleep(for: .milliseconds(1000))
            await send(.updateEnhancementProgress(.idle))
          }
        )
      }
      // Show edit overlay for user to review/edit before pasting
      return .merge(
        .send(.updateEnhancementProgress(.completed)),
        .run { _ in
          await soundEffect.play(.enhancementComplete)
        },
        .send(.showEditOverlay(result)),
        .run { send in
          // Clear progress after a short delay
          try await Task.sleep(for: .milliseconds(1000))
          await send(.updateEnhancementProgress(.idle))
        }
      )
    } else {
      // Direct paste without overlay
      return .merge(
        .send(.updateEnhancementProgress(.completed)),

        // Play enhancement complete sound
        .run { _ in
          await soundEffect.play(.enhancementComplete)
        },

        // 只粘貼結果，不保存歷史記錄
        .run { _ in
          await pasteboard.paste(result)
          await soundEffect.play(.pasteTranscript)
        },
        .run { send in
          // Clear progress after a short delay
          try await Task.sleep(for: .milliseconds(1000))
          await send(.updateEnhancementProgress(.idle))
        }
      )
    }
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

  // DISABLED: History功能暫時停用
  // /// Move file to permanent location, create a transcript record, paste text, and play sound.
  // func finalizeRecordingAndStoreTranscript(
  //   result: String,
  //   duration: TimeInterval,
  //   transcriptionHistory: Shared<TranscriptionHistory>
  // ) -> Effect<Action> {
  //   .run { send in
  //     // Detect potential transcription failure (long recording but short/empty text)
  //     let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
  //     if duration >= 10 && trimmed.count < 10 {
  //       await send(.setTranscriptionFailedAlert(true))
  //     }
  //
  //     do {
  //       let originalURL = await recording.stopRecording()
  //
  //       // Move the file to a permanent location
  //       let fm = FileManager.default
  //       let supportDir = try fm.url(
  //         for: .applicationSupportDirectory,
  //         in: .userDomainMask,
  //         appropriateFor: nil,
  //         create: true
  //       )
  //       let ourAppFolder = supportDir.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
  //       let recordingsFolder = ourAppFolder.appendingPathComponent("Recordings", isDirectory: true)
  //       try fm.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
  //
  //       // Create a unique file name
  //       let filename = "\(Date().timeIntervalSince1970).wav"
  //       let finalURL = recordingsFolder.appendingPathComponent(filename)
  //
  //       // Move temp => final
  //       try fm.moveItem(at: originalURL, to: finalURL)
  //
  //       // Build a transcript object
  //       let transcript = Transcript(
  //         timestamp: Date(),
  //         text: result,
  //         audioPath: finalURL,
  //         duration: duration
  //       )
  //
  //       // Append to the in-memory shared history
  //       transcriptionHistory.withLock {
  //         $0.history.insert(transcript, at: 0)
  //       }
  //
  //       // Paste text (and copy if enabled via pasteWithClipboard)
  //       await pasteboard.paste(result)
  //       await soundEffect.play(.pasteTranscript)
  //     } catch {
  //       await send(.transcriptionError(error))
  //     }
  //   }
  // }
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
    
    // Reset meter and progress states so UI returns to idle state
    state.meter = .init(averagePower: 0, peakPower: 0)
    // Reset progress states
    state.recordingProgress = RecordingProgress()
    state.enhancementProgress.updateStage(.idle)
    state.streamingTranscription.reset()
    state.realTimeTranscription = nil

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.delayedRecord),
      .cancel(id: CancelID.recordingPulse),
      .cancel(id: CancelID.recordingFeedback),
      .cancel(id: CancelID.enhancementFeedback),
      .cancel(id: CancelID.streamTranscription),
      .cancel(id: CancelID.screenshotCapture),
      .cancel(id: CancelID.hotKeyWatchdog),
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

// MARK: - HotKey Watchdog helpers

private extension TranscriptionFeature {
  /// Returns `true` iff the entire hotkey chord (key + modifiers) is currently pressed.
  static func isHotKeyCurrentlyPressed(_ hotkey: HotKey) -> Bool {
    // 1) Key component (if any)
    if let key = hotkey.key {
      let keyCode = SafeSauce.safeKeyCode(for: key)
        if !CGEventSource.keyState(.combinedSessionState, key: keyCode) {
        return false
      }
    }

    // 2) Modifier component(s)
    let flags = CGEventSource.flagsState(.combinedSessionState)

    for mod in hotkey.modifiers.modifiers {
      switch mod {
      case .command:
        if !flags.contains(.maskCommand) { return false }
      case .option:
        if !flags.contains(.maskAlternate) { return false }
      case .shift:
        if !flags.contains(.maskShift) { return false }
      case .control:
        if !flags.contains(.maskControl) { return false }
      case .fn:
        if !flags.contains(.maskSecondaryFn) { return false }
      }
    }

    return true
  }
}

// MARK: - Language Utilities
private extension TranscriptionFeature {
  /// Normalizes language codes for WhisperKit compatibility
  /// Converts zh-cn/zh-tw to zh for WhisperKit processing
  static func normalizeLanguageForWhisper(_ language: String?) -> String? {
    guard let language = language else { return nil }
    
    // WhisperKit uses "zh" for all Chinese variants
    if language.hasPrefix("zh") {
      return "zh"
    }
    
    return language
  }
}

// MARK: - Hallucination Text Filtering

private extension TranscriptionFeature {
  /// Checks if the given text is likely to be hallucination from Whisper
  static func isLikelyHallucinationText(_ text: String) -> Bool {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    // Return true for empty or very short text
    guard cleaned.count >= 2 else { return true }

    // Known long hallucination patterns from Whisper models (substring match)
    // These are notorious hallucinations from Chinese YouTube/Bilibili training data
    // Check these FIRST regardless of text length
    let longHallucinationPatterns = [
      "請不吝點贊",
      "訂閱轉發",
      "打賞支持",
      "明鏡與點點",
      "點點欄目",
      "支持明鏡",
      "歡迎訂閱",
      "記得點贊",
      "喜歡就訂閱"
    ]

    for pattern in longHallucinationPatterns {
      if cleaned.contains(pattern) {
        return true
      }
    }

    // For longer text (>15 chars), only check long hallucination patterns above
    // Don't apply short phrase checks to avoid false positives
    guard cleaned.count <= 15 else { return false }

    // Common Whisper hallucination phrases (Chinese and English)
    // Only check these for short text to avoid false positives
    let commonHallucinations = [
      // English common hallucinations
      "thank you", "thank you.", "thanks", "thanks.",
      "goodbye", "bye", "bye.", "see you",
      "okay", "ok", "ok.", "alright",
      "hello", "hi", "hey", "hey.",
      "subtitle", "subtitles", "caption", "captions",
      "music", "bgm", "background music",
      "applause", "clapping", "silence",
      "the end", "end", "that's it", "done",
      // Chinese common hallucinations
      "謝謝", "謝謝大家", "感謝", "感謝大家",
      "再見", "拜拜", "掰掰", "下次見",
      "好的", "好", "沒問題", "知道了",
      "你好", "哈囉", "嗨", "大家好",
      "字幕", "音樂", "背景音樂", "掌聲",
      "結束", "完了", "就這樣", "沒了"
    ]

    // Check exact matches with common hallucinations
    if commonHallucinations.contains(cleaned) {
      return true
    }

    // Check for repeating patterns (like "好好好", "謝謝謝謝")
    if hasRepeatingPattern(cleaned) {
      return true
    }

    // Check for sequences of single repeated characters
    if isRepeatedSingleCharacter(cleaned) {
      return true
    }

    return false
  }
  
  /// Detects repeating patterns in text
  private static func hasRepeatingPattern(_ text: String) -> Bool {
    guard text.count >= 4 else { return false }
    
    let chars = Array(text)
    let maxPatternLength = chars.count / 2
    
    // Check for patterns of length 1 to maxPatternLength
    for patternLength in 1...maxPatternLength {
      let pattern = String(chars[0..<patternLength])
      let expectedRepeats = chars.count / patternLength
      
      // If we can repeat this pattern to fill most of the string, it's likely repetitive
      if expectedRepeats >= 2 {
        let reconstructed = String(repeating: pattern, count: expectedRepeats)
        if text.hasPrefix(reconstructed) && reconstructed.count >= chars.count * 3 / 4 {
          return true
        }
      }
    }
    
    return false
  }
  
  /// Detects text that's just a single character repeated
  private static func isRepeatedSingleCharacter(_ text: String) -> Bool {
    guard text.count >= 3 else { return false }
    let firstChar = text.first
    return text.allSatisfy { $0 == firstChar }
  }
}

// MARK: - Debug Logging Helper

private func debugLog(_ message: String) {
  let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tok_overlay_debug.log")
  let timestamp = ISO8601DateFormatter().string(from: Date())
  let line = "[\(timestamp)] \(message)\n"
  if let data = line.data(using: .utf8) {
    if FileManager.default.fileExists(atPath: logFile.path) {
      if let handle = try? FileHandle(forWritingTo: logFile) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
      }
    } else {
      try? data.write(to: logFile)
    }
  }
}
