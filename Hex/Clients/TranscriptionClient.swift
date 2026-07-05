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
  var transcribe: @Sendable (URL, String, DecodingOptions, HexSettings?, @escaping (Progress) -> Void) async throws -> String

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
  var startStreamTranscription: @Sendable (String, DecodingOptions, HexSettings?, @escaping (StreamTranscriptionUpdate) -> Void) async throws -> Void
  
  /// Stops the current streaming transcription
  var stopStreamTranscription: @Sendable () async -> Void
  
  /// Gets the tokenizer for the currently loaded model, if available
  var getTokenizer: @Sendable () async -> WhisperTokenizer?

  /// Cleans up raw Whisper tokens from text
  var cleanWhisperTokens: @Sendable (String) -> String = { $0 }
}

extension TranscriptionClient: DependencyKey {
  static var liveValue: Self {
    let live = TranscriptionClientLive()
    return Self(
      transcribe: { try await live.transcribe(url: $0, model: $1, options: $2, settings: $3, progressCallback: $4) },
      downloadModel: { try await live.downloadAndLoadModel(variant: $0, progressCallback: $1) },
      deleteModel: { try await live.deleteModel(variant: $0) },
      isModelDownloaded: { await live.isModelDownloaded($0) },
      getRecommendedModels: { await live.getRecommendedModels() },
      getAvailableModels: { try await live.getAvailableModels() },
      prewarmModel: { try await live.prewarmModel(variant: $0, progressCallback: $1) },
      startStreamTranscription: { try await live.startStreamTranscription(model: $0, options: $1, settings: $2, updateCallback: $3) },
      stopStreamTranscription: { await live.stopStreamTranscription() },
      getTokenizer: { await live.getTokenizer() },
      cleanWhisperTokens: { live.cleanWhisperTokens(from: $0) }
    )
  }
}

// MARK: - Performance Extensions

private extension Character {
  /// Performance optimized check for Chinese characters (CJK range)
  var isChineseCharacter: Bool {
    let scalar = unicodeScalars.first?.value ?? 0
    // Chinese character ranges (simplified check for performance)
    return (0x4E00...0x9FFF).contains(scalar) || // CJK Unified Ideographs
           (0x3400...0x4DBF).contains(scalar) || // CJK Extension A  
           (0x20000...0x2A6DF).contains(scalar)  // CJK Extension B
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

  /// The base folder under which we store model data (e.g., ~/Library/Application Support/...).
  private lazy var modelsBaseFolder: URL = {
    do {
      let appSupportURL = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      // Typically: .../Application Support/com.kitlangton.Hex
      let ourAppFolder = appSupportURL.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
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

      // Path: <Application Support>/com.kitlangton.Hex/models/argmaxinc/whisperkit-coreml/*
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
  /// Performance optimized: smarter model reuse logic
  func prewarmModel(variant: String, progressCallback: @escaping (Progress) -> Void) async throws {
    print("[TranscriptionClientLive] prewarmModel - checking model: '\(variant)' vs current: '\(currentModelName ?? "nil")', whisperKit: \(whisperKit != nil), isStreamingActive: \(isStreamingActive)")

    // Performance optimization: fast path for already loaded model
    if variant == currentModelName && whisperKit != nil {
      let progress = Progress(totalUnitCount: 100)
      progress.completedUnitCount = 100
      progressCallback(progress)
      print("[TranscriptionClientLive] Model \(variant) already prewarmed (fast path)")
      return
    }

    // Don't prewarm if streaming is active to avoid interrupting transcription
    if isStreamingActive {
      print("[TranscriptionClientLive] prewarmModel - skipping prewarming while streaming is active")
      let progress = Progress(totalUnitCount: 100)
      progress.completedUnitCount = 100
      progressCallback(progress)
      return
    }

    // Performance optimization: avoid unnecessary unload if models are similar
    // (This could be enhanced further with model compatibility checks)
    if whisperKit == nil || variant != currentModelName {
      // Only unload if we're switching to a different model
      if currentModelName != nil && currentModelName != variant {
        unloadCurrentModel()
      }
      try await downloadAndLoadModel(variant: variant, progressCallback: progressCallback)
      print("[TranscriptionClientLive] Prewarmed model: \(variant)")
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

    // Perform the transcription.
    let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)

    // Build text using segment-level gaps (from VAD chunking) to insert punctuation.
    // Each segment is a continuous speech chunk; gaps between segments = speaker pauses.
    let rawText = buildTextWithSegmentPausePunctuation(from: results)

    // Performance optimization: process text in single pass (cleaning + conversion)
    var text = processTranscriptionText(rawText, settings: settings)
    
    // Use provided settings or default to auto-capitalization
    let useAutoCapitalization = settings == nil ? true : !settings!.disableAutoCapitalization
    
    // Convert to lowercase if auto-capitalization is disabled
    if !useAutoCapitalization {
      text = text.lowercased()
    }
    
    return text
  }

  // MARK: - Segment-Based Pause Punctuation

  /// Uses VAD segment boundaries to insert punctuation based on speaker pauses.
  /// WhisperKit with `chunkingStrategy: .vad` splits audio at silence gaps.
  /// Each segment = one continuous speech chunk. We examine the gap between
  /// consecutive segments to decide punctuation:
  /// - Gap ≥ 0.15s (short segments) → enumeration comma 、
  /// - Gap ≥ 0.3s → comma ， or enumeration comma 、
  /// - Gap ≥ 0.8s → period 。, question mark ？, or exclamation mark ！
  /// No word-level timestamps needed — preserves transcription quality for Chinese.
  private nonisolated func buildTextWithSegmentPausePunctuation(
    from results: [TranscriptionResult]
  ) -> String {
    // Flatten all segments across results, preserving order
    let allSegments = results.flatMap(\.segments)

    guard allSegments.count >= 2 else {
      // Single segment (common with Large model) — use conjunction-based
      // punctuation as fallback when segment timing isn't available.
      let plain = results.map(\.text).joined(separator: " ")
      let withPunctuation = insertPunctuationAtClauseBoundaries(plain)
      print("[TranscriptionClient] Single-segment fallback: conjunction-based punctuation")
      #if DEBUG
      Self.appendDiagnostic("[Punctuation] single-segment fallback: \(results.count) results, text='\(plain)'\n")
      #endif
      return normalizePunctuation(withPunctuation)
    }

    let segments = allSegments.map {
      TranscriptionSegment(text: $0.text, start: TimeInterval($0.start), end: TimeInterval($0.end))
    }
    print("[TranscriptionClient] Segment-pause punctuation: \(segments.count) segments")
    return punctuatedText(from: segments)
  }

  nonisolated func punctuatedText(from segments: [TranscriptionSegment]) -> String {
    // Adaptive thresholds: slow speakers pause longer everywhere, so anchor
    // thresholds to this recording's own rhythm (median inter-segment gap)
    // instead of absolute seconds. Only scales up — fast speech keeps the
    // absolute floors, so short recordings behave exactly as before.
    let gaps = zip(segments.dropFirst(), segments).map { max(0, $0.start - $1.end) }
    var scale: TimeInterval = 1.0
    if gaps.count >= 3 {
      let median = gaps.sorted()[gaps.count / 2]
      scale = min(max(median / 0.3, 1.0), 3.0)
    }
    let enumerationThreshold: TimeInterval = 0.15 * scale
    let commaThreshold: TimeInterval = 0.3 * scale
    let periodThreshold: TimeInterval = 0.8 * scale

    // Diagnostic (debug builds only): segment boundaries and gap timings
    #if DEBUG
    let gapSummary = gaps.map { String(format: "%.2f", $0) }.joined(separator: ", ")
    var diagnostic = "[Punctuation] \(segments.count) segments, scale=\(String(format: "%.2f", scale)), gaps=[\(gapSummary)]\n"
    for (i, seg) in segments.enumerated() {
      diagnostic += "[Punctuation]   seg[\(i)] \(String(format: "%.2f–%.2f", seg.start, seg.end)) '\(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))'\n"
    }
    Self.appendDiagnostic(diagnostic)
    #endif

    var output = ""
    for i in 0..<segments.count {
      let segment = segments[i]
      // Strip raw Whisper tokens (<|zh|>, <|1.28|>…) BEFORE analysis:
      // punctuation inserted around tokens survives dedup as "。，" once the
      // tokens are removed downstream, and tokens break suffix/adjacency checks
      let text = cleanWhisperTokens(from: segment.text)
      guard !text.isEmpty else { continue }

      output += text

      // Check gap to next segment
      if i + 1 < segments.count {
        let gap = segments[i + 1].start - segment.end
        let nextText = cleanWhisperTokens(from: segments[i + 1].text)

        // Only insert punctuation if text doesn't already end with one
        let lastChar = text.last ?? Character(" ")
        let alreadyPunctuated = "。，？！；：、.?!,;:？！，".contains(lastChar)

        if !alreadyPunctuated {
          var handled = false

          // A pause right after a forward-binding connective (一旦/如果/但是…)
          // is speaker hesitation, not a clause boundary: the connective
          // belongs to the NEXT clause, so punctuation goes before it
          // (…有快有慢，一旦如果…). A segment that is only a connective gets
          // no punctuation at all.
          if gap >= commaThreshold, let (body, connective) = splitTrailingConnective(text) {
            if !body.isEmpty {
              output.removeLast(connective.count)
              let punct = gap >= periodThreshold
                ? determineSentenceEndPunctuation(body)
                : "，"
              output += punct + connective
            }
            handled = true
          } else if gap >= commaThreshold, endsWithNonFinalTail(text) {
            // A pause after a word that cannot end a sentence (重點在於…)
            // is thinking hesitation — always a comma, never a period
            output += "，"
            handled = true
          } else if gap >= commaThreshold, startsWithBackwardBindingOpener(nextText) {
            // Next segment continues this clause (還是/或者/而且…) — the
            // sentence is not over regardless of pause length (MOE: 選擇問句
            // 只在句末用問號)
            output += "，"
            handled = true
          } else if gap >= periodThreshold {
            // Long pause → sentence end: pick 。/？/！ based on content
            output += determineSentenceEndPunctuation(text)
            handled = true
          } else if gap >= commaThreshold {
            // Medium pause → clause break: pick ，or 、based on context,
            // but never before a coordinating conjunction (MOE: 頓號不與
            // 連接詞並用 — 蘋果、香蕉和橘子)
            if !startsWithCoordinatingConjunction(nextText) {
              output += determineClausePunctuation(text, next: nextText)
            }
            handled = true
          } else if gap >= enumerationThreshold {
            // Short pause → only insert 、for enumeration-like patterns,
            // and never before a coordinating conjunction
            if splitTrailingConnective(text) == nil,
               looksLikeEnumeration(text, next: nextText),
               !startsWithCoordinatingConjunction(nextText) {
              output += "、"
              handled = true
            }
          }

          // Zero/short gap but the next segment opens with a discourse
          // marker (當然/其實…): the VAD split plus the opener is enough
          // evidence of a clause boundary
          if !handled, startsWithDiscourseOpener(nextText) {
            output += "，"
          }
        }
      }
    }

    // Also apply clause-boundary markers within segments (VAD only handles
    // inter-segment gaps; intra-segment clause boundaries need explicit markers)
    output = insertPunctuationAtClauseBoundaries(output)

    // Normalize and clean up punctuation
    output = normalizePunctuation(output)

    return output
  }

  // MARK: - Punctuation Classification

  /// Picks sentence-ending punctuation based on content analysis.
  /// Only called when a long pause (≥ 0.8s) is detected between segments.
  private nonisolated func determineSentenceEndPunctuation(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if isQuestionPattern(trimmed) { return "？" }
    if isExclamatoryPattern(trimmed) { return "！" }
    return "。"
  }

  /// Picks clause-level punctuation: 、for enumeration-like pairs, ，otherwise.
  private nonisolated func determineClausePunctuation(_ text: String, next nextText: String) -> String {
    if looksLikeEnumeration(text, next: nextText) {
      return "、"
    }
    return "，"
  }

  /// Detects Chinese question patterns.
  private nonisolated func isQuestionPattern(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }

    // 0. Rhetorical questions (反問句) — MOE: 反問用問號（你不肯，難道我肯？）
    let rhetoricalMarkers = ["難道", "豈不", "豈能", "何必", "何嘗"]
    for marker in rhetoricalMarkers {
      if text.contains(marker) { return true }
    }

    // 1. Question-ending particles (語氣助詞)
    let questionEndings = ["嗎", "呢", "麼", "嘛"]
    for ending in questionEndings {
      if text.hasSuffix(ending) { return true }
    }

    // Indirect questions (間接問句) — MOE: 疑問詞只是陳述句的一部分時用句號
    // （我不知道他去哪裡。）Embedding predicates suppress the checks below,
    // but never the final particles above (你知道嗎 is still a question).
    let embeddingPredicates = [
      "知道", "曉得", "清楚", "記得", "明白", "瞭解", "了解",
      "告訴", "好奇", "關心", "取決", "問",
    ]
    if embeddingPredicates.contains(where: { text.contains($0) }) {
      return false
    }

    // 2. A-not-A patterns (反覆問句)
    let aNotAPatterns = [
      "是不是", "有沒有", "能不能", "可不可以", "會不會",
      "要不要", "對不對", "好不好", "行不行", "願不願意",
      "算不算", "夠不夠", "想不想",
    ]
    for pattern in aNotAPatterns {
      if text.contains(pattern) { return true }
    }

    // 3. Choice questions: 「A還是B」 pattern — only when 還是 connects two options,
    //    not when used as adverb meaning "still" (e.g. 還是有很多問題)
    if let range = text.range(of: "還是") {
      let afterStillIdx = range.upperBound
      // "還是" as choice requires a noun/clause after, not 有/很/不/沒/會/比較 (adverbial "still")
      if afterStillIdx < text.endIndex {
        let charAfter = text[afterStillIdx]
        let adverbFollowers: Set<Character> = ["有", "很", "不", "沒", "會", "要", "得", "比", "能", "可", "應", "該", "算", "蠻", "挺", "滿"]
        if !adverbFollowers.contains(charAfter) {
          return true
        }
      }
    }

    // 4. Trailing interrogative adverbs (句末疑問)
    let trailingQuestion = ["多少", "幾個", "幾天", "幾次", "什麼", "怎樣", "如何", "哪裡"]
    for word in trailingQuestion {
      if text.hasSuffix(word) { return true }
    }

    return false
  }

  /// Detects Chinese exclamatory / imperative patterns.
  private nonisolated func isExclamatoryPattern(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }

    // 1. Degree-complement endings (程度補語)
    let degreeEndings = ["死了", "極了", "透了", "壞了", "慘了", "爆了", "翻了"]
    for ending in degreeEndings {
      if text.hasSuffix(ending) { return true }
    }

    // 2. Emphatic exclamatory particles
    let exclamatoryEndings = ["耶", "哇", "噢", "唷", "欸", "咧"]
    for ending in exclamatoryEndings {
      if text.hasSuffix(ending) { return true }
    }

    // 3. Strong exclamatory / imperative phrases
    let strongKeywords = [
      "救命", "天啊", "我的天", "太棒了", "太好了", "太厲害",
      "太扯", "夠了", "閉嘴", "不要啊", "好痛", "好可怕",
    ]
    for keyword in strongKeywords {
      if text.contains(keyword) { return true }
    }

    // 4. Imperative verbs at the start (祈使句)
    let imperativeStarters = ["別", "不要", "不准", "不許", "快", "趕快", "馬上", "立刻", "給我"]
    for starter in imperativeStarters {
      if text.hasPrefix(starter) { return true }
    }

    // 5. Exclamatory sentences (感嘆句) — MOE: 好大的雨啊！
    //    Degree adverb + sentence-final particle 啊/呀/哪
    if let last = text.last, "啊呀哪".contains(last) {
      let degreeAdverbs = ["好", "真", "太", "多麼"]
      if degreeAdverbs.contains(where: { text.contains($0) }) { return true }
    }

    return false
  }

  /// Heuristic: two segments look like an enumeration (列舉) when both are
  /// short noun-like phrases (≤ 5 Chinese characters each).
  private nonisolated func looksLikeEnumeration(_ text: String, next nextText: String) -> Bool {
    let currentCJKCount = text.filter(\.isChineseCharacter).count
    let nextCJKCount = nextText.filter(\.isChineseCharacter).count
    // Both segments are short — likely parallel list items
    return currentCJKCount >= 1 && currentCJKCount <= 5
        && nextCJKCount >= 1 && nextCJKCount <= 5
  }

  #if DEBUG
  /// Appends a diagnostic line to a log file (debug builds only,
  /// stdout is discarded for LaunchServices-launched apps).
  nonisolated static func appendDiagnostic(_ text: String, to path: String = "/tmp/tok-punctuation.log") {
    print(text, terminator: "")
    let url = URL(fileURLWithPath: path)
    guard let data = text.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url)
    }
  }
  #endif

  // MARK: - Clause Marker Vocabulary

  /// Connectives that bind to the FOLLOWING clause and cannot end one.
  /// A pause right after any of these is speaker hesitation — punctuation
  /// belongs before the connective, never after it.
  /// Sorted longest-first to prevent partial matches.
  private static let forwardBindingConnectives: [String] = [
    // Adversative (轉折)
    "但是", "然而", "可是", "不過",
    // Consequential (因果)
    "所以", "因此", "因而",
    // Causal (原因)
    "因為", "由於",
    // Additive (遞進)
    "而且", "並且", "況且", "另外", "此外", "同時",
    // Concessive (讓步)
    "雖然", "儘管", "即使",
    // Conditional (條件)
    "如果", "假如", "要是", "一旦", "只要", "除非",
    // Alternative consequence (否則類)
    "否則", "不然",
    // Sequential (順序)
    "然後", "接著", "接下來",
    // Disjunctive (選擇)
    "或者", "或是",
  ].sorted { $0.count > $1.count }

  /// Conditional connectives that commonly appear right after a subject
  /// (天氣一旦變冷、你只要說) or between short noun phrases (牛奶或是咖啡).
  /// Safe as pause-relocation anchors, but too noisy for blind comma
  /// insertion inside continuous text.
  private static let relocationOnlyConnectives: Set<String> = ["一旦", "只要", "除非", "或是"]

  /// Words that cannot end a sentence (在於/就是/例如…). A long pause after
  /// one is thinking hesitation — it demotes to a comma, never a period.
  private static let nonFinalTails: [String] = [
    "在於", "對於", "關於", "屬於", "等於", "位於",
    "就是", "而是", "像是", "甚至是",
    "例如", "譬如", "比如", "包括", "以及", "加上",
  ]

  /// Discourse openers: a segment BEGINNING with one of these marks a new
  /// clause even when the gap is zero — the VAD split plus the opener word
  /// is evidence enough (…獲得均衡｜當然如果… → 均衡，當然).
  /// Includes imperative starters (請/麻煩): a segment opening with one
  /// starts a new imperative clause (…不太適合在戶外走動，請注意安全).
  private static let discourseOpeners: [String] = [
    "當然", "其實", "事實上", "總之", "簡單來說",
    "坦白說", "老實說", "說真的", "基本上", "換句話說", "也就是說", "總而言之",
    "請", "麻煩",
  ]

  private nonisolated func endsWithNonFinalTail(_ text: String) -> Bool {
    Self.nonFinalTails.contains { text.hasSuffix($0) }
  }

  private nonisolated func startsWithDiscourseOpener(_ text: String) -> Bool {
    Self.discourseOpeners.contains { text.hasPrefix($0) }
  }

  /// Openers that bind BACKWARD — the previous clause is not finished, so a
  /// pause before one takes a comma, never a period. MOE: 選擇問句只在句末
  /// 用問號（今天是星期六，還是星期日？）。
  private static let backwardBindingOpeners: [String] = [
    "還是", "或者", "或是", "而且", "並且", "以及", "甚至",
  ]

  private nonisolated func startsWithBackwardBindingOpener(_ text: String) -> Bool {
    Self.backwardBindingOpeners.contains { text.hasPrefix($0) }
  }

  /// Coordinating conjunctions that replace enumeration punctuation entirely.
  /// MOE: 頓號不與連接詞並用（蘋果、香蕉和橘子）。
  private static let coordinatingConjunctions: [String] = [
    "和", "與", "及", "跟", "或", "還有",
  ]

  private nonisolated func startsWithCoordinatingConjunction(_ text: String) -> Bool {
    Self.coordinatingConjunctions.contains { text.hasPrefix($0) }
  }

  /// Temporal adverbs are clause starters only in some positions — they also
  /// appear as noun-phrase modifiers (現在的工作), so insertion needs context
  /// guards. 之前/之後 are excluded entirely: they are frequently
  /// postpositional (去美國之前) and structurally unpredictable.
  private static let temporalMarkers: [String] = [
    "目前", "現在", "後來", "剛才", "最近", "當時",
  ]

  /// Discourse markers (語篇).
  private static let discourseMarkers: [String] = [
    "其實", "事實上", "總之", "簡單來說",
  ]

  /// If the text ends with a forward-binding connective, split it off.
  private nonisolated func splitTrailingConnective(_ text: String) -> (body: String, connective: String)? {
    for marker in Self.forwardBindingConnectives where text.hasSuffix(marker) {
      return (String(text.dropLast(marker.count)), marker)
    }
    return nil
  }

  // MARK: - Clause-Boundary Punctuation Fallback

  /// Fallback for single-segment results (common with Large model):
  /// Inserts commas before clause-boundary markers (conjunctions, temporal adverbs,
  /// discourse markers) when VAD segment timing is not available.
  nonisolated func insertPunctuationAtClauseBoundaries(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    let hasChinese = text.contains(where: { $0.isChineseCharacter })
    guard hasChinese else { return text }

    var result = text
    let allPunct: Set<Character> = ["。", "，", "？", "！", "；", "：", "、"]

    // Insertion list — sorted longest-first to prevent partial matches
    let clauseMarkers = (
      Self.forwardBindingConnectives.filter { !Self.relocationOnlyConnectives.contains($0) }
        + Self.temporalMarkers
        + Self.discourseMarkers
    ).sorted { $0.count > $1.count }

    for marker in clauseMarkers {
      var searchStart = result.startIndex
      while searchStart < result.endIndex,
            let range = result.range(of: marker, range: searchStart..<result.endIndex) {
        // Skip if marker is at the very start of text
        guard range.lowerBound != result.startIndex else {
          searchStart = range.upperBound
          continue
        }

        // Skip if there's already punctuation right before
        let charBefore = result[result.index(before: range.lowerBound)]
        guard !allPunct.contains(charBefore) else {
          searchStart = range.upperBound
          continue
        }

        // Skip if the marker directly follows another connective — compound
        // clusters like 一旦如果 or 但是如果 must not be split internally
        let prefix = result[..<range.lowerBound]
        guard !Self.forwardBindingConnectives.contains(where: { prefix.hasSuffix($0) }) else {
          searchStart = range.upperBound
          continue
        }

        // Temporal adverbs in noun-phrase or prepositional contexts are not
        // clause boundaries (現在的工作、從現在開始)
        if Self.temporalMarkers.contains(marker) {
          if range.upperBound < result.endIndex, result[range.upperBound] == "的" {
            searchStart = range.upperBound
            continue
          }
          if "的在從到比是了".contains(charBefore) {
            searchStart = range.upperBound
            continue
          }
        }

        // Insert ，before the clause marker
        result.insert("，", at: range.lowerBound)
        // Advance past the inserted comma + the marker
        let offset = result.distance(from: result.startIndex, to: range.lowerBound)
        let newOffset = offset + 1 + marker.count // +1 for the inserted comma
        searchStart = result.index(result.startIndex, offsetBy: min(newOffset, result.count))
      }
    }

    return result
  }

  /// Normalizes punctuation in transcription output:
  /// 1. Converts half-width punctuation to full-width for Chinese text
  /// 2. Removes duplicate/consecutive punctuation (e.g. "?。" → "？")
  /// 3. Adds ending punctuation if missing
  nonisolated func normalizePunctuation(_ text: String) -> String {
    var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { return result }

    // Step 0: Strip U+FFFD — byte-level tokens truncated at a decode-window
    // boundary decode to the replacement character
    result = result.replacingOccurrences(of: "\u{FFFD}", with: "")

    // Step 1: Half-width → full-width for Chinese-containing text
    let hasChinese = result.contains(where: { $0.isChineseCharacter })
    if hasChinese {
      let replacements: [(String, String)] = [
        ("?", "？"), ("!", "！"), (",", "，"), (";", "；"), (":", "："),
      ]
      for (half, full) in replacements {
        result = result.replacingOccurrences(of: half, with: full)
      }
    }

    // Step 1.5: Collapse whitespace between two punctuation marks so the
    // dedup below sees them as consecutive ("。 ：" → "。：")
    while true {
      let collapsed = result.replacingOccurrences(
        of: "([。，？！；：、])\\s+([。，？！；：、])",
        with: "$1$2",
        options: .regularExpression
      )
      if collapsed == result { break }
      result = collapsed
    }

    // Step 2: Remove consecutive punctuation — keep only the first meaningful one
    // e.g. "？。" → "？", "。，" → "。"
    let allPunctuation: Set<Character> = ["。", "，", "？", "！", "；", "：", "、"]
    var cleaned = ""
    var lastWasPunctuation = false
    for char in result {
      if allPunctuation.contains(char) {
        if !lastWasPunctuation {
          cleaned.append(char)
        }
        lastWasPunctuation = true
      } else {
        cleaned.append(char)
        lastWasPunctuation = false
      }
    }
    result = cleaned

    // Step 3: Add ending punctuation if missing
    if let last = result.last, !allPunctuation.contains(last) {
      if isQuestionPattern(result) {
        result += "？"
      } else if isExclamatoryPattern(result) {
        result += "！"
      } else {
        result += "。"
      }
    }

    return result
  }

  // MARK: - Private Helpers

  /// Converts Simplified Chinese text to Traditional Chinese characters
  /// Performance optimized: early return for non-Chinese text
  private nonisolated func convertToTraditionalChinese(_ text: String) -> String {
    // Performance optimization: skip conversion for empty or non-Chinese text
    guard !text.isEmpty, text.contains(where: { $0.isChineseCharacter }) else {
      return text
    }
    
    // Use Swift's string transform to convert Simplified to Traditional Chinese
    return text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? text
  }
  
  /// Performance optimized: processes text in single pass (cleaning + conversion + custom words)
  private nonisolated func processTranscriptionText(_ text: String, settings: HexSettings?) -> String {
    // Early return for empty text
    guard !text.isEmpty else { return text }

    print("[processTranscriptionText] Input: '\(text)'")

    // Step 1: Clean Whisper tokens
    var processed = cleanWhisperTokens(from: text)
    print("[processTranscriptionText] After cleaning: '\(processed)'")

    // Step 2: Apply Traditional Chinese conversion if enabled
    if let settings = settings, settings.preferTraditionalChinese {
      // Convert if language is explicitly set to Chinese OR if language not set but text contains Chinese
      let languageIsChineseOrUnset = settings.outputLanguage?.hasPrefix("zh") == true || settings.outputLanguage == nil
      let textContainsChinese = processed.contains(where: { $0.isChineseCharacter })

      if languageIsChineseOrUnset && textContainsChinese {
        processed = convertToTraditionalChinese(processed)
        print("[processTranscriptionText] After Traditional Chinese conversion: '\(processed)'")
      }
    }

    // Step 2.5: Smart text processing (filler removal + self-correction)
    if let settings = settings, (settings.removeFillerWords || settings.resolveSelfCorrections) {
        let processor = TextProcessor()
        let options = TextProcessingOptions(
            removeFillers: settings.removeFillerWords,
            resolveSelfCorrections: settings.resolveSelfCorrections,
            detectedLanguage: settings.outputLanguage
        )
        processed = processor.process(processed, options: options)
        print("[processTranscriptionText] After text processing: '\(processed)'")
    }

    // Step 3: Apply custom word replacements
    let customWordDictionary = getCachedCustomWordDictionary()
    print("[processTranscriptionText] Dictionary isEnabled: \(customWordDictionary.isEnabled), entries: \(customWordDictionary.entries.count), replacementEntries: \(customWordDictionary.enabledReplacementEntries.count)")
    let beforeReplacement = processed
    processed = customWordDictionary.applyReplacements(to: processed)
    print("[processTranscriptionText] After replacements: '\(processed)' (changed: \(beforeReplacement != processed))")

    // Step 3.5: Phonetic glossary correction — repairs homophone-class
    // misrecognitions of standard terms (whole glossary, no prompt-token cost)
    let beforeGlossary = processed
    processed = getCachedPhoneticGlossary().correct(processed)
    if beforeGlossary != processed {
      print("[processTranscriptionText] After phonetic glossary: '\(processed)'")
    }

    return processed
  }

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
  // Performance optimization: avoid unnecessary unloading if the same model is being used.
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

    // Guard every decode against the prefill-EOT abort bug — see
    // PrefillEOTSuppressionFilter. Injected once per model load; applies to
    // decodes with and without promptTokens (harmless for the latter: it
    // only forces each window to emit at least one real token).
    if let whisperKit, let tokenizer = whisperKit.tokenizer {
      let eotFilter = PrefillEOTSuppressionFilter(
        endToken: tokenizer.specialTokens.endToken,
        startOfTranscriptToken: tokenizer.specialTokens.startOfTranscriptToken
      )
      // The built-in TimestampRulesFilter disables itself when promptTokens
      // are in use — this port re-enables timestamp coherence for prompted
      // decodes only. See PromptTimestampRulesFilter.
      let timestampFilter = PromptTimestampRulesFilter(
        timeTokenBegin: tokenizer.specialTokens.timeTokenBegin,
        endToken: tokenizer.specialTokens.endToken,
        noTimestampsToken: tokenizer.specialTokens.noTimestampsToken,
        startOfPreviousToken: tokenizer.specialTokens.startOfPreviousToken,
        startOfTranscriptToken: tokenizer.specialTokens.startOfTranscriptToken
      )
      whisperKit.textDecoder.logitsFilters =
        (whisperKit.textDecoder.logitsFilters ?? []) + [eotFilter, timestampFilter]
    }

    #if DEBUG
    // Mirror WhisperKit's internal debug log to a file so decode aborts
    // (EOT sampled during prefill, temperature fallbacks) are observable —
    // stdout is discarded for LaunchServices-launched apps. Filtered to the
    // decode-loop lines that reveal where and why a window stopped.
    Logging.shared.logLevel = .debug
    Logging.shared.loggingCallback = { message in
      let keep = message.contains("Fallback")
        || message.contains("Completed window")
        || message.contains("Predicted next tokenIndex")
        || message.contains("Running main loop")
        || message.contains("Decoding Temperature")
      guard keep else { return }
      Self.appendDiagnostic("[WhisperKit] \(message)\n", to: "/tmp/tok-whisperkit.log")
    }
    #endif

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
  /// Performance optimized with compiled regex and early returns
  nonisolated func cleanWhisperTokens(from text: String) -> String {
    // Performance optimization: early return for empty text
    guard !text.isEmpty else { return text }
    
    // Performance optimization: skip processing if no tokens detected
    guard text.contains("<|") else { 
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var cleaned = text
    
    // Performance optimized: use single combined regex pattern
    let combinedPattern = "<\\|(?:startoftranscript|endoftranscript|endoftext|transcribe|translate|nospeech|notimestamps|\\w{2,3}|\\d+\\.\\d+|[^|]*)\\|>"
    
    cleaned = cleaned.replacingOccurrences(
      of: combinedPattern,
      with: "",
      options: .regularExpression
    )
    
    // Clean up multiple spaces and trim in one pass
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
    updateCallback: @escaping (StreamTranscriptionUpdate) -> Void
  ) async throws {
    // Stop any existing stream
    await stopStreamTranscription()

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

    print("[TranscriptionClientLive] Starting stream transcription with model: \(model)")

    // Create AudioStreamTranscriber with weak self reference to prevent crashes
    let streamTranscriber = AudioStreamTranscriber(
      audioEncoder: whisperKit.audioEncoder,
      featureExtractor: whisperKit.featureExtractor,
      segmentSeeker: whisperKit.segmentSeeker,
      textDecoder: whisperKit.textDecoder,
      tokenizer: tokenizer,
      audioProcessor: whisperKit.audioProcessor,
      decodingOptions: options
    ) { [weak self] oldState, newState in
      // Safely access self to prevent EXC_BAD_ACCESS
      guard let self = self else {
        print("[TranscriptionClientLive] Self deallocated during callback, skipping update")
        return
      }
      
      // Performance optimization: process text in single pass
      let cleanedText = self.processTranscriptionText(newState.currentText, settings: settings)
      
      // Skip empty/waiting updates to reduce noise, but allow real transcription through
      if cleanedText.isEmpty || cleanedText == "Waiting for speech..." {
        // Skip these updates silently to avoid log spam
        return
      }
      
      print("[TranscriptionClientLive] Stream callback triggered - Raw text: '\(newState.currentText)'")
      print("[TranscriptionClientLive] Confirmed segments count: \(newState.confirmedSegments.count)")
      print("[TranscriptionClientLive] Unconfirmed segments count: \(newState.unconfirmedSegments.count)")
      print("[TranscriptionClientLive] Cleaned text: '\(cleanedText)'")
      
      // Performance optimization: process segments efficiently
      let confirmedSegments = newState.confirmedSegments.map { segment in
        TranscriptionSegment(
          text: self.processTranscriptionText(segment.text, settings: settings),
          start: TimeInterval(segment.start),
          end: TimeInterval(segment.end)
        )
      }
      
      let unconfirmedSegments = newState.unconfirmedSegments.map { segment in
        TranscriptionSegment(
          text: self.processTranscriptionText(segment.text, settings: settings),
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

    // Stop the audio stream transcriber
    if let streamTranscriber = audioStreamTranscriber {
      await streamTranscriber.stopStreamTranscription()
      audioStreamTranscriber = nil
      print("[TranscriptionClientLive] AudioStreamTranscriber stopped and cleared")
    }

    print("[TranscriptionClientLive] Stream transcription stopped completely, streaming now inactive")
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
