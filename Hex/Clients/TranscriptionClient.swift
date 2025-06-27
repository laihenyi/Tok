//
//  TranscriptionClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation
import WhisperKit

// MARK: - Stream Transcription Types

struct StreamTranscriptionUpdate: Equatable {
  let confirmedSegments: [TranscriptionSegment]
  let unconfirmedSegments: [TranscriptionSegment]
  let currentText: String
  let isComplete: Bool
}

struct TranscriptionSegment: Equatable {
  let text: String
  let start: TimeInterval
  let end: TimeInterval
}

/// A client that downloads and loads WhisperKit models, then transcribes audio files using the loaded model.
/// Exposes progress callbacks to report overall download-and-load percentage and transcription progress.
@DependencyClient
struct TranscriptionClient {
  /// Transcribes an audio file at the specified `URL` using the named `model`.
  /// Reports transcription progress via `progressCallback`.
  /// Optionally accepts HexSettings for features like auto-capitalization.
  /// Optionally accepts previousTranscript for rolling context in chunked transcription.
  var transcribe: @Sendable (URL, String, DecodingOptions, HexSettings?, String?, @escaping (Progress) -> Void) async throws -> String

  /// Ensures a model is downloaded (if missing) and loaded into memory, reporting progress via `progressCallback`.
  var downloadModel: @Sendable (String, @escaping (Progress) -> Void) async throws -> Void

  /// Deletes a model from disk if it exists
  var deleteModel: @Sendable (String) async throws -> Void

  /// Checks if a named model is already downloaded on this system.
  var isModelDownloaded: @Sendable (String) async -> Bool = { _ in false }

  /// Fetches a recommended set of models for the user's hardware from Hugging Face's `argmaxinc/whisperkit-coreml`.
  var getRecommendedModels: @Sendable () async throws -> ModelSupport

  /// Lists all model variants found in `argmaxinc/whisperkit-coreml`.
  var getAvailableModels: @Sendable () async throws -> [String]

  /// Prewarms a model by loading it into memory without transcribing anything.
  var prewarmModel: @Sendable (String, @escaping (Progress) -> Void) async throws -> Void

  /// Starts streaming transcription from microphone using AudioStreamTranscriber
  /// Returns updates via the callback with real-time transcription progress
  /// Optionally accepts previousTranscript for rolling context in streaming transcription
  var startStreamTranscription: @Sendable (String, DecodingOptions, HexSettings?, String?, @escaping (StreamTranscriptionUpdate) -> Void) async throws -> Void
  
  /// Stops the current streaming transcription
  var stopStreamTranscription: @Sendable () async -> Void

  /// Resets any cached context or state to ensure clean isolation between different transcription modes
  var resetContext: @Sendable () async -> Void

  /// Gets the tokenizer for the currently loaded model, if available
  var getTokenizer: @Sendable () async -> WhisperTokenizer?

  /// Cleans up raw Whisper tokens from text
  var cleanWhisperTokens: @Sendable (String) -> String = { $0 }
}

extension TranscriptionClient: DependencyKey {
  static var liveValue: Self {
    let live = TranscriptionClientLive()
    return Self(
      transcribe: { try await live.transcribe(url: $0, model: $1, options: $2, settings: $3, previousTranscript: $4, progressCallback: $5) },
      downloadModel: { try await live.downloadAndLoadModel(variant: $0, progressCallback: $1) },
      deleteModel: { try await live.deleteModel(variant: $0) },
      isModelDownloaded: { await live.isModelDownloaded($0) },
      getRecommendedModels: { await live.getRecommendedModels() },
      getAvailableModels: { try await live.getAvailableModels() },
      prewarmModel: { try await live.prewarmModel(variant: $0, progressCallback: $1) },
      startStreamTranscription: { try await live.startStreamTranscription(model: $0, options: $1, settings: $2, previousTranscript: $3, updateCallback: $4) },
      stopStreamTranscription: { await live.stopStreamTranscription() },
      resetContext: { await live.resetContext() },
      getTokenizer: { await live.getTokenizer() },
      cleanWhisperTokens: { live.cleanWhisperTokens(from: $0) }
    )
  }
}

extension DependencyValues {
  var transcription: TranscriptionClient {
    get { self[TranscriptionClient.self] }
    set { self[TranscriptionClient.self] = newValue }
  }
}

/// An `actor` that manages WhisperKit models by downloading (from Hugging Face),
//  loading them into memory, and then performing transcriptions.

actor TranscriptionClientLive {
  // MARK: - Stored Properties

  /// The current in-memory `WhisperKit` instance, if any.
  private var whisperKit: WhisperKit?

  /// The name of the currently loaded model, if any.
  private var currentModelName: String?
  
  /// The current AudioStreamTranscriber instance for streaming transcription
  private var audioStreamTranscriber: AudioStreamTranscriber?

  /// Task managing the streaming transcription
  private var streamTask: Task<Void, Error>?

  /// Flag to track if streaming transcription is currently active
  private var isStreamingActive: Bool = false

  /// Track the source of the current stream to help debug conflicts
  private var currentStreamSource: String?

  /// The base folder under which we store model data (e.g., ~/Library/Application Support/...).
  private lazy var modelsBaseFolder: URL = {
    do {
      let appSupportURL = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      // Typically: .../Application Support/xyz.2qs.Tok
      let ourAppFolder = appSupportURL.appendingPathComponent("xyz.2qs.Tok", isDirectory: true)
      // Inside there, store everything in /models
      let baseURL = ourAppFolder.appendingPathComponent("models", isDirectory: true)
      try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
      return baseURL
    } catch {
      fatalError("Could not create Application Support folder: \(error)")
    }
  }()

  // MARK: - Public Methods

  /// Ensures the given `variant` model is downloaded and loaded, reporting
  /// overall progress (0%–50% for downloading, 50%–100% for loading).
  func downloadAndLoadModel(variant: String, progressCallback: @escaping (Progress) -> Void) async throws {
    // Special handling for corrupted or malformed variant names
    if variant.isEmpty {
      throw NSError(
        domain: "TranscriptionClient",
        code: -3,
        userInfo: [
          NSLocalizedDescriptionKey: "Cannot download model: Empty model name"
        ]
      )
    }
    
    let overallProgress = Progress(totalUnitCount: 100)
    overallProgress.completedUnitCount = 0
    progressCallback(overallProgress)
    
    print("[TranscriptionClientLive] Processing model: \(variant)")

    // 1) Model download phase (0-50% progress)
    if !(await isModelDownloaded(variant)) {
      try await downloadModelIfNeeded(variant: variant) { downloadProgress in
        let fraction = downloadProgress.fractionCompleted * 0.5
        overallProgress.completedUnitCount = Int64(fraction * 100)
        progressCallback(overallProgress)
      }
    } else {
      // Skip download phase if already downloaded
      overallProgress.completedUnitCount = 50
      progressCallback(overallProgress)
    }

    // 2) Model loading phase (50-100% progress)
    try await loadWhisperKitModel(variant) { loadingProgress in
      let fraction = 0.5 + (loadingProgress.fractionCompleted * 0.5)
      overallProgress.completedUnitCount = Int64(fraction * 100)
      progressCallback(overallProgress)
    }
    
    // Final progress update
    overallProgress.completedUnitCount = 100
    progressCallback(overallProgress)
  }

  /// Deletes a model from disk if it exists
  func deleteModel(variant: String) async throws {
    let modelFolder = modelPath(for: variant)
    
    // Check if the model exists
    guard FileManager.default.fileExists(atPath: modelFolder.path) else {
      // Model doesn't exist, nothing to delete
      return
    }
    
    // If this is the currently loaded model, unload it first
    if currentModelName == variant {
      unloadCurrentModel()
    }
    
    // Delete the model directory
    try FileManager.default.removeItem(at: modelFolder)
    
    print("[TranscriptionClientLive] Deleted model: \(variant)")
  }

  /// Returns `true` if the model is already downloaded to the local folder.
  /// Performs a thorough check to ensure the model files are actually present and usable.
  func isModelDownloaded(_ modelName: String) async -> Bool {
    let modelFolderPath = modelPath(for: modelName).path
    let fileManager = FileManager.default
    
    // First, check if the basic model directory exists
    guard fileManager.fileExists(atPath: modelFolderPath) else {
      // Don't print logs that would spam the console
      return false
    }
    
    do {
      // Check if the directory has actual model files in it
      let contents = try fileManager.contentsOfDirectory(atPath: modelFolderPath)
      
      // Model should have multiple files and certain key components
      guard !contents.isEmpty else {
        return false
      }
      
      // Check for specific model structure - need both tokenizer and model files
      let hasModelFiles = contents.contains { $0.hasSuffix(".mlmodelc") || $0.contains("model") }
      let tokenizerFolderPath = tokenizerPath(for: modelName).path
      let hasTokenizer = fileManager.fileExists(atPath: tokenizerFolderPath)
      
      // Both conditions must be true for a model to be considered downloaded
      return hasModelFiles && hasTokenizer
    } catch {
      return false
    }
  }

  /// Returns a list of recommended models based on current device hardware.
  func getRecommendedModels() async -> ModelSupport {
    await WhisperKit.recommendedRemoteModels()
  }

  /// Lists all model variants available in the `argmaxinc/whisperkit-coreml` repository.
  func getAvailableModels() async throws -> [String] {
    do {
      // Primary path: fetch full list of models from Hugging Face
      return try await WhisperKit.fetchAvailableModels()
    } catch {
      // Fallback: enumerate any models that are already downloaded locally so that
      // previously-downloaded models remain selectable even when offline or when
      // the Hugging Face API is unreachable.

      // Path: <Application Support>/xyz.2qs.Tok/models/argmaxinc/whisperkit-coreml/*
      let repoFolder = modelsBaseFolder
        .appendingPathComponent("argmaxinc")
        .appendingPathComponent("whisperkit-coreml", isDirectory: true)

      let fm = FileManager.default

      // Gracefully handle the case where the directory doesn't exist (no downloads yet)
      guard let contents = try? fm.contentsOfDirectory(
        at: repoFolder,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) else {
        // If we cannot list the directory, rethrow the original network error so the caller
        // can decide how to react.
        throw error
      }

      // Filter for sub-directories that actually contain a valid downloaded model
      var localModels: [String] = []
      for url in contents {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
          let name = url.lastPathComponent
          let downloaded = await self.isModelDownloaded(name)
          if downloaded {
            localModels.append(name)
          }
        }
      }

      // Return whatever we found (may be empty). This guarantees that the caller always
      // receives a list of *at least* the locally-cached models even when offline.
      return localModels.sorted()
    }
  }

  /// Prewarms a model by loading it into memory without transcribing anything.
  /// This is useful for reducing latency when the user switches models in settings.
  func prewarmModel(variant: String, progressCallback: @escaping (Progress) -> Void) async throws {
    print("[TranscriptionClientLive] prewarmModel - checking model: '\(variant)' vs current: '\(currentModelName ?? "nil")', whisperKit: \(whisperKit != nil), isStreamingActive: \(isStreamingActive)")

    // Don't prewarm if streaming is active to avoid interrupting transcription
    if isStreamingActive {
      print("[TranscriptionClientLive] prewarmModel - skipping prewarming while streaming is active")
      let progress = Progress(totalUnitCount: 100)
      progress.completedUnitCount = 100
      progressCallback(progress)
      return
    }

    // Only load if it's not already the current model
    if whisperKit == nil || variant != currentModelName {
      unloadCurrentModel()
      try await downloadAndLoadModel(variant: variant, progressCallback: progressCallback)
      print("[TranscriptionClientLive] Prewarmed model: \(variant)")
    } else {
      // Model is already loaded, just report completion
      let progress = Progress(totalUnitCount: 100)
      progress.completedUnitCount = 100
      progressCallback(progress)
      print("[TranscriptionClientLive] Model \(variant) already prewarmed")
    }
  }

  /// Transcribes the audio file at `url` using a `model` name.
  /// If the model is not yet loaded (or if it differs from the current model), it is downloaded and loaded first.
  /// Transcription progress can be monitored via `progressCallback`.
  func transcribe(
    url: URL,
    model: String,
    options: DecodingOptions,
    settings: HexSettings? = nil,
    previousTranscript: String? = nil,
    progressCallback: @escaping (Progress) -> Void
  ) async throws -> String {
    
    // Load or switch to the required model if needed.
    print("[TranscriptionClientLive] transcribe - checking model: '\(model)' vs current: '\(currentModelName ?? "nil")', whisperKit: \(whisperKit != nil), isStreamingActive: \(isStreamingActive)")

    // If streaming is active and we're using the same model, avoid reloading
    if isStreamingActive && model == currentModelName && whisperKit != nil {
      print("[TranscriptionClientLive] transcribe - streaming active with same model, skipping reload")
    } else if whisperKit == nil || model != currentModelName {
      print("[TranscriptionClientLive] transcribe - model reload needed: whisperKit=\(whisperKit == nil), modelMismatch=\(model != currentModelName)")
      unloadCurrentModel()
      try await downloadAndLoadModel(variant: model) { p in
        // Debug logging, or scale as desired:
        progressCallback(p)
      }
    } else {
      print("[TranscriptionClientLive] transcribe - using existing model: \(model)")
    }

    guard let whisperKit = whisperKit else {
      throw NSError(
        domain: "TranscriptionClient",
        code: -1,
        userInfo: [
          NSLocalizedDescriptionKey: "Failed to initialize WhisperKit for model: \(model)",
        ]
      )
    }

    // Build decoding options with optional previous transcript context
    var decodeOptions = options
    
    // Add previous transcript to prompt tokens if provided
    if let previousTranscript = previousTranscript, !previousTranscript.trimmingCharacters(in: .whitespaces).isEmpty,
       let tokenizer = whisperKit.tokenizer {
      let trimmedPrevious = previousTranscript.trimmingCharacters(in: .whitespaces)
      let previousTokens = tokenizer.encode(text: " " + trimmedPrevious)
        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
      
      // Append to existing prompt tokens if any, otherwise use the previous transcript tokens
      if let existingTokens = decodeOptions.promptTokens {
        decodeOptions.promptTokens = existingTokens + previousTokens
        print("[TranscriptionClientLive] Appended previous transcript context (\(previousTokens.count) tokens) to existing prompt tokens (\(existingTokens.count) tokens): '\(trimmedPrevious)'")
      } else {
        decodeOptions.promptTokens = previousTokens
        print("[TranscriptionClientLive] Applied previous transcript context with \(previousTokens.count) tokens: '\(trimmedPrevious)'")
      }
      decodeOptions.usePrefillPrompt = false
    }

    // Perform the transcription.
    let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: decodeOptions)

    // Concatenate results from all segments.
    var text = results.map(\.text).joined(separator: " ")
    
    // Use provided settings or default to auto-capitalization
    let useAutoCapitalization = settings == nil ? true : !settings!.disableAutoCapitalization
    
    // Convert to lowercase if auto-capitalization is disabled
    if !useAutoCapitalization {
      text = text.lowercased()
    }
    
    return text
  }

  // MARK: - Private Helpers

  /// Creates or returns the local folder (on disk) for a given `variant` model.
  private func modelPath(for variant: String) -> URL {
    // Remove any possible path traversal or invalid characters from variant name
    let sanitizedVariant = variant.components(separatedBy: CharacterSet(charactersIn: "./\\")).joined(separator: "_")
    
    return modelsBaseFolder
      .appendingPathComponent("argmaxinc")
      .appendingPathComponent("whisperkit-coreml")
      .appendingPathComponent(sanitizedVariant, isDirectory: true)
  }

  /// Creates or returns the local folder for the tokenizer files of a given `variant`.
  private func tokenizerPath(for variant: String) -> URL {
    modelPath(for: variant).appendingPathComponent("tokenizer", isDirectory: true)
  }

  // Unloads any currently loaded model (clears `whisperKit` and `currentModelName`).
  private func unloadCurrentModel() {
    print("[TranscriptionClientLive] Unloading current model: \(currentModelName ?? "none"), isStreamingActive: \(isStreamingActive)")

    // Make sure to stop any streaming first to prevent crashes
    Task {
      await stopStreamTranscription()
    }

    whisperKit = nil
    currentModelName = nil

    print("[TranscriptionClientLive] Model unloaded successfully")
  }

  /// Downloads the model to a temporary folder (if it isn't already on disk),
  /// then moves it into its final folder in `modelsBaseFolder`.
  private func downloadModelIfNeeded(
    variant: String,
    progressCallback: @escaping (Progress) -> Void
  ) async throws {
    let modelFolder = modelPath(for: variant)
    
    // If the model folder exists but isn't a complete model, clean it up
    let isDownloaded = await isModelDownloaded(variant)
    if FileManager.default.fileExists(atPath: modelFolder.path) && !isDownloaded {
      try FileManager.default.removeItem(at: modelFolder)
    }
    
    // If model is already fully downloaded, we're done
    if isDownloaded {
      return
    }

    print("[TranscriptionClientLive] Downloading model: \(variant)")

    // Create parent directories
    let parentDir = modelFolder.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    
    do {
      // Download directly using the exact variant name provided
      let tempFolder = try await WhisperKit.download(
        variant: variant,
        downloadBase: nil,
        useBackgroundSession: false,
        from: "argmaxinc/whisperkit-coreml",
        token: nil,
        progressCallback: { progress in
          progressCallback(progress)
        }
      )
      
      // Ensure target folder exists
      try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
      
      // Move the downloaded snapshot to the final location
      try moveContents(of: tempFolder, to: modelFolder)
      
      print("[TranscriptionClientLive] Downloaded model to: \(modelFolder.path)")
    } catch {
      // Clean up any partial download if an error occurred
      if FileManager.default.fileExists(atPath: modelFolder.path) {
        try? FileManager.default.removeItem(at: modelFolder)
      }
      
      // Rethrow the original error
      print("[TranscriptionClientLive] Error downloading model: \(error.localizedDescription)")
      throw error
    }
  }

  /// Loads a local model folder via `WhisperKitConfig`, optionally reporting load progress.
  private func loadWhisperKitModel(
    _ modelName: String,
    progressCallback: @escaping (Progress) -> Void
  ) async throws {
    let loadingProgress = Progress(totalUnitCount: 100)
    loadingProgress.completedUnitCount = 0
    progressCallback(loadingProgress)

    let modelFolder = modelPath(for: modelName)
    let tokenizerFolder = tokenizerPath(for: modelName)

    // Use WhisperKit's config to load the model
    let config = WhisperKitConfig(
      model: modelName,
      modelFolder: modelFolder.path,
      tokenizerFolder: tokenizerFolder,
      // verbose: true,
      // logLevel: .debug,
      prewarm: true,
      load: true
    )

    // The initializer automatically calls `loadModels`.
    whisperKit = try await WhisperKit(config)
    currentModelName = modelName

    // Finalize load progress
    loadingProgress.completedUnitCount = 100
    progressCallback(loadingProgress)

    print("[TranscriptionClientLive] Loaded WhisperKit model: \(modelName)")
  }

  /// Moves all items from `sourceFolder` into `destFolder` (shallow move of directory contents).
  private func moveContents(of sourceFolder: URL, to destFolder: URL) throws {
    let fileManager = FileManager.default
    let items = try fileManager.contentsOfDirectory(atPath: sourceFolder.path)
    for item in items {
      let src = sourceFolder.appendingPathComponent(item)
      let dst = destFolder.appendingPathComponent(item)
      try fileManager.moveItem(at: src, to: dst)
    }
  }
  
  /// Cleans up raw Whisper tokens from streaming transcription text
  nonisolated func cleanWhisperTokens(from text: String) -> String {
    var cleaned = text
    
    // Remove Whisper special tokens
    let whisperTokenPatterns = [
      // lets remove all the <|...|> tokens
      "<[\\|]?[^>]+[\\|]?>",
      "^\\s*", // Leading whitespace
      "\\s*$"  // Trailing whitespace
    ]
    
    for pattern in whisperTokenPatterns {
      cleaned = cleaned.replacingOccurrences(
        of: pattern,
        with: "",
        options: .regularExpression
      )
    }
    
    // Clean up multiple spaces and trim
    cleaned = cleaned.replacingOccurrences(
      of: "\\s+",
      with: " ",
      options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    
    return cleaned
  }
  
  // MARK: - Streaming Transcription
  
  /// Starts streaming transcription from microphone using AudioStreamTranscriber
  func startStreamTranscription(
    model: String,
    options: DecodingOptions,
    settings: HexSettings? = nil,
    previousTranscript: String? = nil,
    updateCallback: @escaping (StreamTranscriptionUpdate) -> Void
  ) async throws {
    // Stop any existing stream first - this is CRITICAL to prevent conflicts
    if isStreamingActive {
      print("[TranscriptionClientLive] WARNING: Stopping existing stream from \(currentStreamSource ?? "unknown") to start new stream")
    }
    await stopStreamTranscription()

    // Add a small delay to ensure cleanup is complete
    try await Task.sleep(for: .milliseconds(100))

    // Load or switch to the required model if needed
    print("[TranscriptionClientLive] startStreamTranscription - checking model: '\(model)' vs current: '\(currentModelName ?? "nil")', whisperKit: \(whisperKit != nil)")
    if whisperKit == nil || model != currentModelName {
      print("[TranscriptionClientLive] startStreamTranscription - model reload needed: whisperKit=\(whisperKit == nil), modelMismatch=\(model != currentModelName)")
      unloadCurrentModel()
      try await downloadAndLoadModel(variant: model) { _ in }
    } else {
      print("[TranscriptionClientLive] startStreamTranscription - using existing model: \(model)")
    }

    guard let whisperKit = whisperKit else {
      throw NSError(
        domain: "TranscriptionClient",
        code: -1,
        userInfo: [
          NSLocalizedDescriptionKey: "Failed to initialize WhisperKit for model: \(model)",
        ]
      )
    }
    
    guard let tokenizer = whisperKit.tokenizer else {
      throw NSError(
        domain: "TranscriptionClient",
        code: -2,
        userInfo: [
          NSLocalizedDescriptionKey: "Tokenizer unavailable for model: \(model)",
        ]
      )
    }

    // Determine source for debugging
    let streamSource = settings != nil ? "KaraokeFeature" : "TranscriptionFeature"
    currentStreamSource = streamSource

    print("[TranscriptionClientLive] Starting stream transcription with model: \(model) from source: \(streamSource)")

    // Build decoding options with optional previous transcript context for streaming
    var streamDecodeOptions = options

    // Add previous transcript to prompt tokens if provided
    if let previousTranscript = previousTranscript, !previousTranscript.trimmingCharacters(in: .whitespaces).isEmpty {
      let trimmedPrevious = previousTranscript.trimmingCharacters(in: .whitespaces)
      let previousTokens = tokenizer.encode(text: " " + trimmedPrevious)
        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }

      // Append to existing prompt tokens if any, otherwise use the previous transcript tokens
      if let existingTokens = streamDecodeOptions.promptTokens {
        streamDecodeOptions.promptTokens = existingTokens + previousTokens
        print("[TranscriptionClientLive] Appended previous transcript context (\(previousTokens.count) tokens) to existing prompt tokens (\(existingTokens.count) tokens) for \(streamSource): '\(trimmedPrevious)'")
      } else {
        streamDecodeOptions.promptTokens = previousTokens
        print("[TranscriptionClientLive] Applied previous transcript context with \(previousTokens.count) tokens for \(streamSource): '\(trimmedPrevious)'")
      }
      streamDecodeOptions.usePrefillPrompt = false
    } else {
      print("[TranscriptionClientLive] No previous transcript context provided for \(streamSource)")
    }

    // Create a deduplication mechanism to prevent duplicate updates
    var lastSentText = ""
    var lastSentSegmentCount = 0

    // Create AudioStreamTranscriber with weak self reference to prevent crashes
    let streamTranscriber = AudioStreamTranscriber(
      audioEncoder: whisperKit.audioEncoder,
      featureExtractor: whisperKit.featureExtractor,
      segmentSeeker: whisperKit.segmentSeeker,
      textDecoder: whisperKit.textDecoder,
      tokenizer: tokenizer,
      audioProcessor: whisperKit.audioProcessor,
      decodingOptions: streamDecodeOptions
    ) { [weak self] oldState, newState in
      // Safely access self to prevent EXC_BAD_ACCESS
      guard let self = self else {
        print("[TranscriptionClientLive] Self deallocated during callback, skipping update")
        return
      }
      
      // Clean up raw Whisper tokens from the text
      let cleanedText = self.cleanWhisperTokens(from: newState.currentText)
      
      // Skip empty/waiting updates to reduce noise, but allow updates that contain a *new* confirmed segment
      if (cleanedText.isEmpty || cleanedText == "Waiting for speech...") && newState.confirmedSegments.count == lastSentSegmentCount {
        // Only skip if both the text is empty *and* there's no new confirmed segment
        return
      }

      // Deduplication: skip if this is the same text and segment count as last sent
      // For KaraokeFeature, be more permissive to allow frequent live updates
      let shouldSkipDuplicate = streamSource == "KaraokeFeature" ? 
        (cleanedText == lastSentText && cleanedText.count > 10 && newState.confirmedSegments.count == lastSentSegmentCount) :
        (cleanedText == lastSentText && newState.confirmedSegments.count == lastSentSegmentCount)
      
      if shouldSkipDuplicate {
        print("[TranscriptionClientLive] Skipping duplicate update: '\(cleanedText)'")
        return
      }

      lastSentText = cleanedText
      lastSentSegmentCount = newState.confirmedSegments.count
      
      print("[TranscriptionClientLive] Stream callback triggered - Raw text: '\(newState.currentText)'")
      print("[TranscriptionClientLive] Confirmed segments count: \(newState.confirmedSegments.count)")
      print("[TranscriptionClientLive] Unconfirmed segments count: \(newState.unconfirmedSegments.count)")
      print("[TranscriptionClientLive] Cleaned text: '\(cleanedText)'")
      
      // Convert WhisperKit segments to our custom format, also cleaning their text
      let confirmedSegments = newState.confirmedSegments.map { segment in
        TranscriptionSegment(
            text: self.cleanWhisperTokens(from: segment.text),
          start: TimeInterval(segment.start),
          end: TimeInterval(segment.end)
        )
      }
      
      let unconfirmedSegments = newState.unconfirmedSegments.map { segment in
        TranscriptionSegment(
            text: self.cleanWhisperTokens(from: segment.text),
          start: TimeInterval(segment.start),
          end: TimeInterval(segment.end)
        )
      }
      
      let update = StreamTranscriptionUpdate(
        confirmedSegments: confirmedSegments,
        unconfirmedSegments: unconfirmedSegments,
        currentText: cleanedText,
        isComplete: false
      )
      
      print("[TranscriptionClientLive] Sending update with cleaned text: '\(update.currentText)'")
      
      updateCallback(update)

    }
    
    self.audioStreamTranscriber = streamTranscriber
    self.isStreamingActive = true
    print("[TranscriptionClientLive] AudioStreamTranscriber created successfully, streaming now active")

    // Start the streaming transcription in a task with proper error handling
    streamTask = Task { [weak self] in
      guard let self = self else {
        print("[TranscriptionClientLive] Self deallocated before stream task started")
        return
      }

      do {
        print("[TranscriptionClientLive] Starting AudioStreamTranscriber...")
        try await streamTranscriber.startStreamTranscription()
        print("[TranscriptionClientLive] Stream transcription completed normally")
      } catch is CancellationError {
        print("[TranscriptionClientLive] Stream transcription was cancelled")
      } catch let error {
        print("[TranscriptionClientLive] Stream transcription error: \(error)")
        // Send a final update to indicate completion with error
        let finalUpdate = StreamTranscriptionUpdate(
          confirmedSegments: [],
          unconfirmedSegments: [],
          currentText: "",
          isComplete: true
        )

        updateCallback(finalUpdate)
        throw error
      }

      // Mark streaming as inactive when task completes
      await self.setStreamingInactive()
    }
  }
  
  /// Stops the current streaming transcription
  func stopStreamTranscription() async {
    print("[TranscriptionClientLive] Stopping stream transcription...")

    // Mark streaming as inactive immediately
    isStreamingActive = false

    // Cancel the stream task first
    if let task = streamTask {
      task.cancel()
      streamTask = nil

      // Wait for the task to complete cancellation to ensure clean shutdown
      do {
        _ = try await task.value
      } catch is CancellationError {
        // Expected - task was cancelled
        print("[TranscriptionClientLive] Stream task cancelled successfully")
      } catch {
        print("[TranscriptionClientLive] Stream task ended with error: \(error)")
      }
    }

    // Stop the audio stream transcriber with proper cleanup
    if let streamTranscriber = audioStreamTranscriber {
      await streamTranscriber.stopStreamTranscription()
      audioStreamTranscriber = nil
      print("[TranscriptionClientLive] AudioStreamTranscriber stopped and cleared")
    }

    // Clear the current stream source
    currentStreamSource = nil
    
    print("[TranscriptionClientLive] Stream transcription stopped completely, streaming now inactive")
  }

  /// Resets any cached context or state to ensure clean isolation between different transcription modes
  func resetContext() async {
    print("[TranscriptionClientLive] Resetting context and state for clean isolation")

    // Stop any active streaming to ensure clean state
    await stopStreamTranscription()

    // Note: We don't unload the model here as that would be expensive and unnecessary
    // The context isolation is handled by passing explicit previousTranscript parameters
    // to transcription methods rather than relying on persistent model state

    print("[TranscriptionClientLive] Context reset completed")
  }

  /// Gets the tokenizer for the currently loaded model, if available
  func getTokenizer() async -> WhisperTokenizer? {
    return whisperKit?.tokenizer
  }

  /// Helper method to mark streaming as inactive
  private func setStreamingInactive() {
    isStreamingActive = false
    print("[TranscriptionClientLive] Streaming marked as inactive")
  }
}
