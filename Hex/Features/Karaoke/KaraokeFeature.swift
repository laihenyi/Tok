import ComposableArchitecture
import SwiftUI
import Foundation
import WhisperKit
import Sauce  // For Key enumeration
import AVFoundation

/// A lightweight feature that shows a live, karaoke-style transcription window and an optional AI response/prompt pane.
/// It intentionally keeps only the information strictly needed for the UI to minimise coupling with the complex
/// `TranscriptionFeature` that powers the rest of the app.
@Reducer
struct KaraokeFeature {
    // MARK: State
    @ObservableState
    struct State: Equatable {
        /// The rolling list of lines that should be displayed in the upper (lyrics) pane.
        public var lines: [Line] = []
        /// Indicates whether the live transcription engine is running.
        public var isTranscribing: Bool = false
        /// The currently-selected tab in the lower pane.
        public var selectedTab: Tab = .response
        /// User-editable prompt (persisted via HexSettings.liveResponsePrompt).
        var promptText: String {
            get { hexSettings.liveResponsePrompt }
            set { $hexSettings.withLock { $0.liveResponsePrompt = newValue } }
        }
        /// Latest AI response to show in the 'Response' tab.
        public var aiResponse: String = ""
        /// Stores a stable proportion for the VSplitView divider (0…1).
        public var splitRatio: CGFloat = 0.6
        /// Track the last finalized transcription chunk for rolling context
        public var lastFinalizedTranscription: String = ""
        /// Current audio meter for VAD
        public var meter: Meter = .init(averagePower: 0, peakPower: 0)
        /// Track when we last detected speech (for silence detection)
        public var lastSpeechTime: Date?
        /// Silence threshold for VAD (average power below this is considered silence)
        public var silenceThreshold: Double = 0.05
        /// Track if we're currently monitoring for silence to avoid duplicate checks
        public var isMonitoringSilence: Bool = false
        /// Track the current live/partial text from WhisperKit for immediate feedback
        public var currentLiveText: String = ""
        /// Track the separator that represents the chunk currently being processed (finalization/enhancement)
        public var currentProcessingSeparatorId: UUID? = nil

        /// Shared settings so we can use the user's preferred transcription model / prompt defaults.
        @Shared(.hexSettings) var hexSettings: HexSettings

        /// Shared transcription history for saving finalized chunks
        @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory

        /// Shared flag indicating whether Karaoke is currently recording
        @Shared(.isKaraokeRecording) var isKaraokeRecording: Bool = false

        public init() {}
    }

    // The smallest displayable unit in the lyrics pane.
    struct Line: Equatable, Identifiable {
        public var id: UUID = .init()
        public var text: String
        public var isHighlighted: Bool = true
        public var type: LineType = .transcription
        public var timestamp: Date?
        /// Optional processing status shown on separator lines
        public var processingStatus: ProcessingStatus? = nil
        
        enum LineType: Equatable {
            case transcription
            case liveText  // For current partial/live transcription
            case separator
            case sessionStart
            case sessionEnd
        }
        
        enum ProcessingStatus: Equatable {
            case transcribing
            case enhancing
        }
        
        // Convenience initializers
        static func transcription(_ text: String, highlighted: Bool = true) -> Line {
            Line(text: text, isHighlighted: highlighted, type: .transcription)
        }
        
        static func liveText(_ text: String) -> Line {
            Line(text: text, isHighlighted: true, type: .liveText)
        }
        
        static func separator(status: ProcessingStatus? = nil, timestamp: Date = Date()) -> Line {
            Line(text: "", isHighlighted: false, type: .separator, timestamp: timestamp, processingStatus: status)
        }
        
        static func sessionStart(timestamp: Date = Date()) -> Line {
            Line(text: "", isHighlighted: false, type: .sessionStart, timestamp: timestamp)
        }
        
        static func sessionEnd(timestamp: Date = Date()) -> Line {
            Line(text: "", isHighlighted: false, type: .sessionEnd, timestamp: timestamp)
        }
    }

    enum Tab: Hashable { case response, prompt }

    // MARK: Actions
    enum Action {
        case startTapped
        case stopTapped
        case _setTranscribing(Bool)

        // Streaming transcription callback
        case streamUpdate(StreamTranscriptionUpdate)
        case _fadeHighlight(id: UUID)
        case _clearLiveText

        // UI bindings
        case setSelectedTab(Tab)
        case setPrompt(String)

        // AI
        case _aiResponse(String)

        // VAD and audio level monitoring
        case audioLevelUpdated(Meter)
        case _checkSilence

        // Transcription finalization (now VAD-based instead of timer-based)
        case _finalizeTranscription
        case _transcriptionFinalized(String)
        case _requestAIResponse

        // Manual chunk finalization via space key
        case keyEvent(KeyEvent)

        // Update processing status on separator
        case _updateProcessingStatus(Line.ProcessingStatus)
        case _saveTranscript(String, URL) // text, audioURL
        case _restartStream
    }

    // MARK: Dependencies & cancellation IDs
    @Dependency(\.transcription) private var transcription
    @Dependency(\.aiEnhancement) private var aiEnhancement
    @Dependency(\.recording) private var recording
    @Dependency(\.screenCapture) private var screenCapture
    @Dependency(\.keyEventMonitor) private var keyEventMonitor
    @Dependency(\.continuousClock) private var clock

    enum CancelID {
        case stream
        case finalize
        case aiRequest
        case audioMonitoring
        case silenceCheck
        case keyEvent
        /// Debounce timer for scheduling AI response generation after confirmed lines are added
        case aiDebounce
    }

    // MARK: Reducer body
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .startTapped:
                guard !state.isTranscribing else { return .none }
                state.isTranscribing = true
                // Notify the rest of the app that Karaoke is now recording.
                state.$isKaraokeRecording.withLock { $0 = true }
                
                // Reset context from any previous session
                state.lines.removeAll()
                state.aiResponse = ""
                state.lastFinalizedTranscription = ""

                state.lines.append(Line.sessionStart())
                // Determine model & options
                let model = state.hexSettings.selectedModel
                let options = DecodingOptions(
                    language: state.hexSettings.outputLanguage,
                    detectLanguage: state.hexSettings.outputLanguage == nil,
                    chunkingStrategy: .vad
                )
                let settings = state.hexSettings

                // First, explicitly cancel any existing stream to prevent overlapping callbacks
                let cancelPreviousEffect: Effect<Action> = .merge(
                    .cancel(id: CancelID.stream),
                    .cancel(id: CancelID.aiRequest),
                    .cancel(id: CancelID.finalize),
                    .cancel(id: CancelID.audioMonitoring),
                    .cancel(id: CancelID.silenceCheck),
                    .cancel(id: CancelID.keyEvent),
                    .cancel(id: CancelID.aiDebounce)
                )

                // 1) Start live (streaming) transcription
                let streamEffect: Effect<Action> = .run { [transcription, model, options, settings] send in
                    // Ensure any existing stream is stopped to prevent conflicts
                    await transcription.stopStreamTranscription()
                    
                    // Small delay to ensure previous stream is fully stopped and callbacks are done
                    try? await Task.sleep(for: .milliseconds(200))
                    
                    // Bridge callback-based API into AsyncStream so the effect stays alive.
                    let updates = AsyncStream<StreamTranscriptionUpdate> { continuation in
                        let task = Task {
                            do {
                                // We no longer pass previousTranscript here to ensure a clean start
                                try await transcription.startStreamTranscription(model, options, settings, nil) { update in
                                    continuation.yield(update)
                                    // WhisperKit convention: final update has isComplete==true
                                    if update.isComplete {
                                        continuation.finish()
                                    }
                                }
                            } catch {
                                // On error, finish the stream so the effect exits gracefully
                                continuation.finish()
                            }
                        }
                        
                        // Ensure proper cleanup when the stream is canceled
                        continuation.onTermination = { _ in
                            task.cancel()
                            Task {
                                await transcription.stopStreamTranscription()
                            }
                        }
                    }

                    for await update in updates {
                        await send(.streamUpdate(update))
                    }
                }
                .cancellable(id: CancelID.stream, cancelInFlight: true)

                // 2) Begin background recording so we can periodically run a high-accuracy pass
                let recordEffect: Effect<Action> = .run { _ in await recording.startRecording() }

                // 3) Monitor audio levels for VAD-based chunking (replaces fixed timer)
                let audioMonitoringEffect: Effect<Action> = .run { [recording] send in
                    // Initialize speech detection
                    await send(.audioLevelUpdated(.init(averagePower: 0, peakPower: 0)))
                    
                    // Monitor audio levels for VAD
                    for await meter in await recording.observeAudioLevel() {
                        await send(.audioLevelUpdated(meter))
                    }
                }
                .cancellable(id: CancelID.audioMonitoring, cancelInFlight: true)

                // 4) Listen for global key events (spacebar to finalize chunk)
                let keyEventEffect: Effect<Action> = .run { [keyEventMonitor] send in
                    do {
                        for try await event in await keyEventMonitor.listenForKeyPress() {
                            await send(.keyEvent(event))
                        }
                    } catch {
                        // Ignore stream errors
                    }
                }
                .cancellable(id: CancelID.keyEvent, cancelInFlight: true)

                return .merge(
                    cancelPreviousEffect,
                    // Add a small delay before starting new effects to ensure cleanup is complete
                    .concatenate(
                        .run { _ in 
                            try? await Task.sleep(for: .milliseconds(50))
                        },
                        .merge(streamEffect, recordEffect, audioMonitoringEffect, keyEventEffect)
                    )
                )

            case .stopTapped:
                guard state.isTranscribing else { return .none }
                state.isTranscribing = false
                // Karaoke recording stopped – reset the shared flag.
                state.$isKaraokeRecording.withLock { $0 = false }
                // Remove any remaining live text lines
                state.lines.removeAll { $0.type == .liveText }
                state.currentLiveText = ""
                // Add final separator to close the transcription session
                if !state.lines.isEmpty {
                    state.lines.append(Line.sessionEnd())
                }
                // Clear the last finalized transcription when stopping
                state.lastFinalizedTranscription = ""
                // Clear VAD state
                state.lastSpeechTime = nil
                state.meter = .init(averagePower: 0, peakPower: 0)
                state.isMonitoringSilence = false
                return .merge(
                    // Cancel all ongoing operations first
                    .cancel(id: CancelID.stream),
                    .cancel(id: CancelID.finalize),
                    .cancel(id: CancelID.aiRequest),
                    .cancel(id: CancelID.audioMonitoring),
                    .cancel(id: CancelID.silenceCheck),
                    .cancel(id: CancelID.keyEvent),
                    .cancel(id: CancelID.aiDebounce),

                    // Then stop services
                    .run { _ in 
                        await transcription.stopStreamTranscription()
                        await recording.stopRecording()
                    }
                )

            case let .streamUpdate(update):
                // Ignore updates if we're not currently transcribing (prevents stale callbacks)
                guard state.isTranscribing else { return .none }
                
                // Count only transcription lines (exclude separators and live text)
                let transcriptionLineCount = state.lines.filter { $0.type == .transcription }.count
                
                var effects: [Effect<Action>] = []
                
                // 1) Handle live/partial text updates IMMEDIATELY for responsive feedback
                let cleanCurrentText = update.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Buffer rule: only accept the new currentText if it is
                // 1) non-empty AND
                // 2) at least as long as the current text.
                // This prevents the UI from flickering when Whisper temporarily
                // emits shorter (or empty) partial hypotheses before extending them again.
                let shouldUpdateLiveText = !cleanCurrentText.isEmpty && 
                                         cleanCurrentText.count >= state.currentLiveText.count &&
                                         cleanCurrentText != state.currentLiveText
                
                if shouldUpdateLiveText {
                    state.currentLiveText = cleanCurrentText
                    
                    // Remove any existing live text line
                    state.lines.removeAll { $0.type == .liveText }
                    
                    // Add new live text line
                    let liveTextLine = Line.liveText(cleanCurrentText)
                    state.lines.append(liveTextLine)
                    
                    // Schedule fade out for live text after a short delay
                    let liveTextId = liveTextLine.id
                    effects.append(.run { send in
                        try? await clock.sleep(for: .seconds(1))
                        await send(._fadeHighlight(id: liveTextId))
                    })
                }
                
                // 2) Handle confirmed segments – append only segments that are genuinely new
                // Gather existing confirmed texts to avoid repetition
                let existingConfirmedTexts: Set<String> = Set(state.lines.filter { $0.type == .transcription }.map { $0.text })

                var appendedAnySegment = false

                for segment in update.confirmedSegments {
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    // Skip if we've already appended the exact same sentence
                    if existingConfirmedTexts.contains(text) { continue }

                    // Append new confirmed line
                    let confirmedLine = Line.transcription(text)
                    state.lines.append(confirmedLine)
                    appendedAnySegment = true

                    // Schedule fade for this confirmed line
                    let confirmedId = confirmedLine.id
                    effects.append(.run { send in
                        try? await clock.sleep(for: .seconds(2))
                        await send(._fadeHighlight(id: confirmedId))
                    })
                }

                if appendedAnySegment {
                    // After appending confirmed segments, remove the live text (if any) shortly after
                    effects.append(.run { send in
                        try? await clock.sleep(for: .milliseconds(100))
                        await send(._clearLiveText)
                    })

                    // Debounce AI response request: wait 3 s after the most recent confirmed segment
                    effects.append(
                        .run { [clock] send in
                            try? await clock.sleep(for: .seconds(3))
                            await send(._requestAIResponse)
                        }
                        .cancellable(id: CancelID.aiDebounce, cancelInFlight: true)
                    )
                }
                
                return .merge(effects)

            case let ._fadeHighlight(id):
                if let idx = state.lines.firstIndex(where: { $0.id == id }) {
                    state.lines[idx].isHighlighted = false
                }
                return .none

            case ._clearLiveText:
                state.lines.removeAll { $0.type == .liveText }
                state.currentLiveText = ""
                return .none

            case let .setSelectedTab(tab):
                state.selectedTab = tab
                return .none
            case let .setPrompt(text):
                state.promptText = text // Writes through computed property to HexSettings.
                return .none

            case let ._aiResponse(text):
                state.aiResponse = text
                return .none

            case ._setTranscribing(let flag):
                state.isTranscribing = flag
                return .none

            case let .audioLevelUpdated(meter):
                state.meter = meter
                
                // VAD logic: detect speech vs silence
                let isSpeech = meter.averagePower > state.silenceThreshold || meter.peakPower > state.silenceThreshold
                
                if isSpeech {
                    // Update last speech time when we detect speech
                    state.lastSpeechTime = Date()
                    // Cancel any ongoing silence monitoring since we detected speech
                    state.isMonitoringSilence = false
                    return .cancel(id: CancelID.silenceCheck)
                } else if state.lastSpeechTime != nil && !state.isMonitoringSilence {
                    // We're in silence, have detected speech before, and not already monitoring - start 3s silence check
                    state.isMonitoringSilence = true
                    return .run { [clock] send in
                        try await clock.sleep(for: .seconds(3))
                        await send(._checkSilence)
                    }
                    .cancellable(id: CancelID.silenceCheck, cancelInFlight: true)
                }
                
                return .none

            case ._checkSilence:
                // Reset monitoring flag
                state.isMonitoringSilence = false
                
                // Check if we're still in silence after the 3-second delay
                guard let lastSpeechTime = state.lastSpeechTime else { return .none }
                
                let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
                let currentlyInSilence = state.meter.averagePower <= state.silenceThreshold && state.meter.peakPower <= state.silenceThreshold
                
                if silenceDuration >= 3.0 && currentlyInSilence {
                    print("[KaraokeFeature] Detected 3+ seconds of silence, finalizing chunk")
                    // Reset speech tracking for next chunk
                    state.lastSpeechTime = nil
                    return .merge(
                        .send(._finalizeTranscription)
                    )
                }
                
                return .none

            case ._finalizeTranscription:
                // Run a non-streaming transcription over the last recorded chunk
                guard state.isTranscribing else { return .none }
                
                // Add a separator line indicating that this chunk is being processed
                let processingSeparator = Line.separator(status: .transcribing)
                state.lines.append(processingSeparator)
                state.currentProcessingSeparatorId = processingSeparator.id
                
                let model = state.hexSettings.selectedModel
                let options = DecodingOptions(
                    language: state.hexSettings.outputLanguage,
                    detectLanguage: state.hexSettings.outputLanguage == nil,
                    chunkingStrategy: .vad
                )
                let settings = state.hexSettings
                let previousTranscript = state.lastFinalizedTranscription

                // Capture the real-time transcription (confirmed + live) since the last separator so we
                // can feed it into the AI enhancement for additional context.
                let realtimeTranscription: String = {
                    // Walk backwards until we hit the most-recent separator or session start.
                    var parts: [String] = []
                    var idx = state.lines.count - 1
                    while idx >= 0 {
                        let line = state.lines[idx]
                        if line.type == .separator || line.type == .sessionStart {
                            break
                        }
                        if line.type == .transcription || line.type == .liveText {
                            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                parts.append(trimmed)
                            }
                        }
                        idx -= 1
                    }
                    // Reverse to restore chronological order.
                    return parts.reversed().joined(separator: " ")
                }()

                // Effect that does the heavy non-streaming transcription + enhancement
                let finalizeEffect: Effect<Action> = .run { [transcription, recording, aiEnhancement, screenCapture, settings, model, options, previousTranscript, realtimeTranscription] send in
                    // Stop the current chunk recording and duplicate it so subsequent recording doesn't overwrite
                    let originalURL = await recording.stopRecording()

                    // Give AVAudioRecorder a brief moment to finish flushing buffers to disk. Without this pause
                    // the file may still be in the process of being finalised which can lead to the copied chunk
                    // being zero-bytes or otherwise unreadable – especially when we restart the recorder almost
                    // immediately afterwards.
                    try? await Task.sleep(for: .milliseconds(150))

                    // Copy to a unique temp file for safe processing
                    let chunkURL: URL = {
                        let tempDir = FileManager.default.temporaryDirectory
                        let filename = "chunk-\(UUID().uuidString).wav"
                        return tempDir.appendingPathComponent(filename)
                    }()
                    do {
                        try FileManager.default.copyItem(at: originalURL, to: chunkURL)
                    } catch {
                        print("[KaraokeFeature] Failed to copy audio chunk: \(error). Falling back to original URL")
                    }

                    // Small delay to ensure recording is properly stopped before starting new one
                    try? await Task.sleep(for: .milliseconds(50))
                    
                    // Start new recording immediately to minimize gaps
                    await recording.startRecording()

                    do {
                        print("[KaraokeFeature] Finalizing transcription with previous context: \(previousTranscript)")
                        // 1) Raw transcription of the recorded chunk with previous context
                        let rawText = try await transcription.transcribe(chunkURL, model, options, settings, previousTranscript) { _ in }
                        print("[KaraokeFeature] Finalized raw transcription: \(rawText)")
                        // Update processing status to enhancing
                        await send(._updateProcessingStatus(.enhancing))

                        // 2) Capture screenshot and get context via VLM
                        var contextSummary: String? = nil
                        do {
                            let imageData = try await screenCapture.captureScreen()
                            let provider = settings.aiProviderType
                            let imgModel = provider == .groq ? settings.selectedRemoteImageModel : settings.selectedImageModel
                            let apiKey = provider == .groq ? (settings.groqAPIKey.isEmpty ? nil : settings.groqAPIKey) : nil
                            let systemPrompt = defaultImageAnalysisPrompt
                            contextSummary = try await aiEnhancement.analyzeImage(
                                imageData,
                                imgModel,
                                settings.imageAnalysisPrompt,
                                provider,
                                apiKey,
                                systemPrompt
                            ) { _ in }
                        } catch {
                            // Non-fatal – carry on without context
                            contextSummary = nil
                        }

                        // 3) Build context: screenshot summary + previous chunk transcript + real-time transcription (if available)
                        var combinedContext: String? = nil
                        if let summary = contextSummary, !summary.isEmpty {
                            combinedContext = summary
                        }
                        if !previousTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if combinedContext != nil {
                                combinedContext = "\(combinedContext!)\nPrevious chunk:\n\(previousTranscript)"
                            } else {
                                combinedContext = "Previous chunk:\n\(previousTranscript)"
                            }
                        }
                        if !realtimeTranscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if combinedContext != nil {
                                combinedContext = "\(combinedContext!)\nREAL_TIME_TRANSCRIPTION:\n\(realtimeTranscription)"
                            } else {
                                combinedContext = "REAL_TIME_TRANSCRIPTION:\n\(realtimeTranscription)"
                            }
                        }

                        print("[KaraokeFeature] Finalizing transcription with combined context: \(combinedContext)")

                        // 4) Enhance the text with AI using combined context
                        // Build enhancement prompt with additional rules.
                        var prompt = settings.aiEnhancementPrompt.isEmpty ? EnhancementOptions.defaultPrompt : settings.aiEnhancementPrompt

                        // Rule to preserve original language when REAL_TIME_TRANSCRIPTION indicates a non-English language.
                        let languageRule = "If the REAL_TIME_TRANSCRIPTION appears to be in a language other than English, your final improved text must be in that same language and must NOT be translated to English."
                        // Rule to format output suitable for karaoke display.
                        let lyricRule = "Break your output into short lines, lyric style."

                        if prompt.isEmpty {
                            prompt = languageRule + "\n\n" + lyricRule
                        } else {
                            prompt += "\n\n" + languageRule + "\n\n" + lyricRule
                        }

                        let enhanceOptions = EnhancementOptions(
                            prompt: prompt,
                            temperature: settings.aiEnhancementTemperature,
                            maxTokens: 1000,
                            context: combinedContext
                        )

                        let provider = settings.aiProviderType
                        let aiModel = provider == .groq ? settings.selectedRemoteModel : settings.selectedAIModel
                        let apiKey = provider == .groq ? (settings.groqAPIKey.isEmpty ? nil : settings.groqAPIKey) : nil

                        let enhancedText: String
                        do {
                            enhancedText = try await aiEnhancement.enhance(rawText, aiModel, enhanceOptions, provider, apiKey) { _ in }
                        } catch {
                            // If AI enhancement fails, fall back to raw text
                            enhancedText = rawText
                        }

                        print("[KaraokeFeature] Finalized enhanced transcription: \(enhancedText)")

                        // 5) Compute duration & request save into history
                        await send(._saveTranscript(enhancedText, chunkURL))

                        await send(._transcriptionFinalized(enhancedText))
                    } catch {
                        // Ignore errors to keep the flow smooth
                    }
                }
                .cancellable(id: CancelID.finalize, cancelInFlight: true)

                // 1) Cancel the live stream immediately
                let cancelStream: Effect<Action> = .cancel(id: CancelID.stream)

                return .merge(cancelStream, finalizeEffect)

            case let ._transcriptionFinalized(text):
                // Clear any remaining live text
                state.lines.removeAll { $0.type == .liveText }
                state.currentLiveText = ""
                
                if let procId = state.currentProcessingSeparatorId,
                   let procIndex = state.lines.firstIndex(where: { $0.id == procId }) {
                    // Remove transcription lines between the previous boundary and the processing separator
                    var idx = procIndex - 1
                    while idx >= 0 {
                        if state.lines[idx].type == .separator || state.lines[idx].type == .sessionStart {
                            break
                        }
                        if state.lines[idx].type == .transcription {
                            state.lines.remove(at: idx)
                        }
                        idx -= 1
                    }
                }
                
                // Split the enhanced text into individual sentences using "\n" and ". " as the delimiter.
                // This ensures each sentence appears on its own line in the karaoke view.
                let newSegments: [String] = text
                    // Replace any line end characters with new line
                    .replacingOccurrences(of: ". ", with: "\n")
                    // Break into sentences by the "\n" pattern.
                    .components(separatedBy: "\n")
                    // Restore the terminating period for segments that lost it during the split, unless the
                    // segment already ends with a different punctuation mark.
                    .map { segment -> String in
                        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return "" }
                        if trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") {
                            return trimmed
                        } else {
                            return "\(trimmed)"
                        }
                    }
                    .filter { !$0.isEmpty }

                if newSegments.isEmpty {
                    // If we received no meaningful content, remove the processing separator entirely
                    if let procId = state.currentProcessingSeparatorId {
                        state.lines.removeAll { $0.id == procId }
                    }
                    state.currentProcessingSeparatorId = nil
                    return .none
                }

                // Ensure there's a separator before finalized chunk.
                if let procId = state.currentProcessingSeparatorId {
                    // Use the existing processing separator: just clear its status
                    if let idx = state.lines.firstIndex(where: { $0.id == procId }) {
                        state.lines[idx].processingStatus = nil
                    }
                } else if state.lines.count > 1 {
                    // Fallback: add new separator if none present
                    state.lines.append(Line.separator())
                }

                // Insert finalized segments (un-highlighted) just before the processing separator so
                // they appear in chronological order (old chunk before the new live chunk).
                if let procId = state.currentProcessingSeparatorId,
                   let separatorIndex = state.lines.firstIndex(where: { $0.id == procId }) {
                    var insertIndex = separatorIndex
                    for segment in newSegments {
                        state.lines.insert(Line.transcription(segment, highlighted: false), at: insertIndex)
                        insertIndex += 1
                    }
                } else {
                    // Fallback: append if the separator cannot be located (shouldn't normally happen).
                    for segment in newSegments {
                        state.lines.append(Line.transcription(segment, highlighted: false))
                    }
                }

                // Store this finalized transcription for future context
                state.lastFinalizedTranscription = text

                // Clear processing separator tracking
                state.currentProcessingSeparatorId = nil

                // Prepare parameters for restarting the live streaming transcription
                let model = state.hexSettings.selectedModel
                let options = DecodingOptions(
                    language: state.hexSettings.outputLanguage,
                    detectLanguage: state.hexSettings.outputLanguage == nil,
                    chunkingStrategy: .vad
                )
                let settings = state.hexSettings
                let previousTranscript = state.lastFinalizedTranscription

                // Effect to restart the streaming transcription
                let restartStreamEffect: Effect<Action> = .run { [transcription, model, options, settings, previousTranscript] send in
                    // Small delay to ensure previous finalize cleaned up resources
                    try? await Task.sleep(for: .milliseconds(100))

                    let updates = AsyncStream<StreamTranscriptionUpdate> { continuation in
                        let task = Task {
                            do {
                                try await transcription.startStreamTranscription(model, options, settings, previousTranscript) { update in
                                    continuation.yield(update)
                                    if update.isComplete { continuation.finish() }
                                }
                            } catch {
                                continuation.finish()
                            }
                        }
                        continuation.onTermination = { _ in
                            task.cancel()
                            Task { await transcription.stopStreamTranscription() }
                        }
                    }

                    for await update in updates {
                        await send(.streamUpdate(update))
                    }
                }
                .cancellable(id: CancelID.stream, cancelInFlight: true)

                // Debounce AI response request after inserting finalized segments
                let debounceEffect: Effect<Action> = .run { [clock] send in
                    try? await clock.sleep(for: .seconds(3))
                    await send(._requestAIResponse)
                }
                .cancellable(id: CancelID.aiDebounce, cancelInFlight: true)

                return .merge(restartStreamEffect, debounceEffect)

            case ._requestAIResponse:
                let transcript = state.lines.map(\.text).joined(separator: "\n")
                guard !transcript.isEmpty else { return .none }
                let hs = state.hexSettings
                let prompt = state.promptText.isEmpty ? EnhancementOptions.defaultPrompt : state.promptText
                let options = EnhancementOptions(
                    prompt: prompt,
                    temperature: hs.aiEnhancementTemperature,
                    maxTokens: 1000,
                    context: nil
                )
                let model = hs.aiProviderType == .groq ? hs.selectedRemoteModel : hs.selectedAIModel
                let apiKey = hs.aiProviderType == .groq ? (hs.groqAPIKey.isEmpty ? nil : hs.groqAPIKey) : nil
                let provider = hs.aiProviderType
                return .run { [aiEnhancement, transcript, model, options, provider, apiKey] send in
                    do {
                        let response = try await aiEnhancement.enhance(transcript, model, options, provider, apiKey) { _ in }
                        await send(._aiResponse(response))
                    } catch {
                        // Silently ignore AI errors
                    }
                }
                .cancellable(id: CancelID.aiRequest, cancelInFlight: true)

            // MARK: - Key Event Handling
            case let .keyEvent(event):
                print("[KaraokeFeature] Key event: \(event)")

                guard state.isTranscribing else { return .none }

                // Only act on space key with no modifiers
                if event.modifiers.isEmpty, let key = event.key {
                    if key == .space || key.rawValue == "space" || key.rawValue == " " {
                        // Cancel any pending silence timer to avoid double-finalisation
                        state.isMonitoringSilence = false
                        state.lastSpeechTime = nil
                        return .merge(
                            .cancel(id: CancelID.silenceCheck),
                            .send(._finalizeTranscription)
                        )
                    }
                }
                return .none

            case let ._updateProcessingStatus(status):
                if let procId = state.currentProcessingSeparatorId, let idx = state.lines.firstIndex(where: { $0.id == procId }) {
                    state.lines[idx].processingStatus = status
                }
                return .none

            case let ._saveTranscript(text, audioURL):
                // Move the temporary chunk file into our permanent "Recordings" folder first
                let finalURL: URL = {
                    do {
                        let fm = FileManager.default
                        // Locate (or create) the app-specific Application Support/Recordings directory
                        let supportDir = try fm.url(
                            for: .applicationSupportDirectory,
                            in: .userDomainMask,
                            appropriateFor: nil,
                            create: true
                        )
                        let ourAppFolder = supportDir.appendingPathComponent("xyz.2qs.Tok", isDirectory: true)
                        let recordingsFolder = ourAppFolder.appendingPathComponent("Recordings", isDirectory: true)
                        try fm.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)

                        // Use the original filename if unique, otherwise fall back to a UUID
                        var destURL = recordingsFolder.appendingPathComponent(audioURL.lastPathComponent)
                        if fm.fileExists(atPath: destURL.path) {
                            destURL = recordingsFolder.appendingPathComponent("\(UUID().uuidString).wav")
                        }

                        // Move the temporary file to its new location. If move fails fall back to original URL.
                        try fm.moveItem(at: audioURL, to: destURL)
                        return destURL
                    } catch {
                        print("[KaraokeFeature] Failed to move audio file to Recordings folder: \(error). Using temporary URL instead.")
                        return audioURL
                    }
                }()

                // Compute duration using AVAudioPlayer to ensure metadata is ready
                let durationSeconds: Double
                do {
                    let player = try AVAudioPlayer(contentsOf: finalURL)
                    durationSeconds = player.duration
                } catch {
                    durationSeconds = 0
                }

                let record = Transcript(timestamp: Date(), text: text, audioPath: finalURL, duration: durationSeconds)
                state.$transcriptionHistory.withLock { history in
                    history.history.insert(record, at: 0)
                }
                return .none

            case ._restartStream:
                // This action is not used now (stream restart handled directly in _transcriptionFinalized) but kept for future flexibility
                return .none
            }
        }
    }
} 