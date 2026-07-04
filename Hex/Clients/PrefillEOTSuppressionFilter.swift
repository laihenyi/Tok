//
//  PrefillEOTSuppressionFilter.swift
//  Hex
//
//  Works around a WhisperKit 0.18 decode-loop bug (TextDecoder.decodeText):
//  the loop samples at every step — including while force-feeding
//  promptTokens (prefill) — and treats a sampled <|endoftext|> as "segment
//  completed" with no prefill guard. A prompt containing sentence-final
//  punctuation makes EOT a likely argmax mid-prompt, aborting the window
//  with an empty transcript (observed 2026-07-04: EOT sampled at prefill
//  index 51 of 88). This filter masks the EOT logit while the decoder is
//  still inside the initial prompt, so decoding always survives prefill
//  and emits at least one real token per window.
//

import CoreML
import WhisperKit

final class PrefillEOTSuppressionFilter: LogitsFiltering, Sendable {
  private let endToken: Int
  private let startOfTranscriptToken: Int

  init(endToken: Int, startOfTranscriptToken: Int) {
    self.endToken = endToken
    self.startOfTranscriptToken = startOfTranscriptToken
  }

  func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
    // During prefill, `tokens` is the full initial prompt and its count stays
    // constant: [<|startofprev|>, …prompt…, SOT, lang, task, timestamp] —
    // the count only grows once real sampling appends tokens. The initial
    // prompt always ends exactly 4 tokens after SOT (SOT, language, task,
    // timestamp/noTimestamps), so count <= sotIndex + 4 identifies prefill
    // plus the first sampled token.
    guard let sotIndex = tokens.firstIndex(of: startOfTranscriptToken),
          tokens.count <= sotIndex + 4
    else { return logits }
    logits.fill(indexes: [[0, 0, endToken as NSNumber]], with: -FloatType.infinity)
    return logits
  }
}
