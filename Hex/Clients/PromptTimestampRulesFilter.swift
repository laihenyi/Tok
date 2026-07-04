//
//  PromptTimestampRulesFilter.swift
//  Hex
//
//  Works around a WhisperKit 0.18 bug: the built-in TimestampRulesFilter
//  locates the task token via tokens.prefix(3), but with promptTokens the
//  initial prompt is [<|startofprev|>, …prompt…, SOT, lang, task, timestamp]
//  and the task token sits far beyond index 3 — the filter finds nothing and
//  disables itself for the whole decode. Without the "if the summed
//  probability of timestamp tokens beats every text token, force a
//  timestamp" rule, greedy sampling at segment boundaries drifts onto
//  stray byte tokens (observed 2026-07-04: fullwidth Ｂ between poem
//  lines, where the no-prompt decode emits <|t1|><|t2|> pairs).
//
//  This is a port of WhisperKit's TimestampRulesFilter with the sample
//  region derived from the SOT position instead of tokens.prefix(3).
//  It activates ONLY when the token stream starts with <|startofprev|>
//  (i.e. promptTokens in use); plain decodes are left to the built-in.
//

import Accelerate
import CoreML
import WhisperKit

final class PromptTimestampRulesFilter: LogitsFiltering, Sendable {
  private let timeTokenBegin: Int
  private let endToken: Int
  private let noTimestampsToken: Int
  private let startOfPreviousToken: Int
  private let startOfTranscriptToken: Int

  init(
    timeTokenBegin: Int,
    endToken: Int,
    noTimestampsToken: Int,
    startOfPreviousToken: Int,
    startOfTranscriptToken: Int
  ) {
    self.timeTokenBegin = timeTokenBegin
    self.endToken = endToken
    self.noTimestampsToken = noTimestampsToken
    self.startOfPreviousToken = startOfPreviousToken
    self.startOfTranscriptToken = startOfTranscriptToken
  }

  func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
    // Only step in for prompted decodes — the built-in filter handles the
    // plain case correctly. The initial prompt always ends exactly 4 tokens
    // after SOT (SOT, language, task, timestamp/noTimestamps).
    guard tokens.first == startOfPreviousToken,
          let sotIndex = tokens.firstIndex(of: startOfTranscriptToken)
    else { return logits }
    let sampleBegin = sotIndex + 4
    guard sampleBegin <= tokens.count else { return logits }

    // Timestamps were requested via the prefill token — never <|notimestamps|>
    logits.fill(indexes: [[0, 0, noTimestampsToken as NSNumber]], with: -FloatType.infinity)

    if tokens.count > sampleBegin {
      // Timestamps have to appear in pairs, except directly before EOT
      let sampledTokens = tokens[sampleBegin...]
      let lastWasTimestamp = sampledTokens.count >= 1 && sampledTokens.last! >= timeTokenBegin
      let penultimateWasTimestamp = sampledTokens.count < 2 || sampledTokens.dropLast().last! >= timeTokenBegin
      if lastWasTimestamp {
        if penultimateWasTimestamp {
          // has to be non-timestamp
          logits.fillLastDimension(indexes: timeTokenBegin..<logits.count, with: -FloatType.infinity)
        } else {
          // cannot be normal text tokens
          logits.fillLastDimension(indexes: 0..<endToken, with: -FloatType.infinity)
        }
      }

      // Timestamps shouldn't decrease; also force nonzero segment length
      let timestamps = sampledTokens.filter { $0 >= timeTokenBegin }
      if let lastTimestamp = timestamps.last {
        let timestampLast =
          if lastWasTimestamp && !penultimateWasTimestamp {
            lastTimestamp
          } else {
            lastTimestamp + 1
          }
        logits.fillLastDimension(indexes: timeTokenBegin..<timestampLast, with: -FloatType.infinity)
      }
    }

    // If the summed probability over timestamps beats every text token,
    // sample a timestamp — this is the rule whose absence produces the
    // stray byte tokens at segment boundaries.
    if sumOfProbabilityOverTimestampsIsAboveAnyOtherToken(logits: logits, timeTokenBegin: timeTokenBegin) {
      logits.fillLastDimension(indexes: 0..<timeTokenBegin, with: -FloatType.infinity)
    }
    return logits
  }

  /// Port of WhisperKit's implementation (LogitsFilter.swift).
  private func sumOfProbabilityOverTimestampsIsAboveAnyOtherToken(
    logits: MLMultiArray, timeTokenBegin: Int
  ) -> Bool {
    let timeTokenBeginOffset = logits.linearOffset(for: [0, 0, timeTokenBegin as NSNumber])

    let logprobsInputPointer = UnsafeMutableRawBufferPointer(
      start: logits.dataPointer,
      count: logits.count * MemoryLayout<FloatType>.stride
    )

    guard let logprobsInputDescriptor = BNNSNDArrayDescriptor(
      data: logprobsInputPointer,
      scalarType: FloatType.self,
      shape: .vector(logits.count, stride: 1)
    ) else { return false }

    let logprobs = BNNSNDArrayDescriptor.allocateUninitialized(
      scalarType: FloatType.self,
      shape: .vector(logits.count, stride: 1)
    )
    defer { logprobs.deallocate() }

    do {
      try BNNS.applyActivation(
        activation: BNNS.ActivationFunction.logSoftmax,
        input: logprobsInputDescriptor,
        output: logprobs,
        batchSize: 1
      )

      let timeTokenCount = logits.count - timeTokenBeginOffset
      let noTimeTokenCount = timeTokenBeginOffset
      let logSumExpInputPointer = UnsafeMutableRawBufferPointer(
        start: logprobs.data!.advanced(by: timeTokenBeginOffset * MemoryLayout<FloatType>.stride),
        count: timeTokenCount * MemoryLayout<FloatType>.stride
      )

      guard let logSumExpInputDescriptor = BNNSNDArrayDescriptor(
        data: logSumExpInputPointer,
        scalarType: FloatType.self,
        shape: .vector(timeTokenCount, stride: 1)
      ) else { return false }

      let timestampLogProb = BNNSNDArrayDescriptor.allocateUninitialized(
        scalarType: FloatType.self,
        shape: .vector(1, stride: 1)
      )
      defer { timestampLogProb.deallocate() }

      try BNNS.applyReduction(
        .logSumExp,
        input: logSumExpInputDescriptor,
        output: timestampLogProb,
        weights: nil
      )

      let maxTextTokenLogProbInputPointer = UnsafeMutableRawBufferPointer(
        start: logprobs.data,
        count: noTimeTokenCount * MemoryLayout<FloatType>.stride
      )

      guard let maxTextTokenLogProbInputDescriptor = BNNSNDArrayDescriptor(
        data: maxTextTokenLogProbInputPointer,
        scalarType: FloatType.self,
        shape: .vector(noTimeTokenCount, stride: 1)
      ) else { return false }

      let maxTextTokenLogProb = BNNSNDArrayDescriptor.allocateUninitialized(
        scalarType: FloatType.self,
        shape: .vector(1, stride: 1)
      )
      defer { maxTextTokenLogProb.deallocate() }

      try BNNS.applyReduction(
        .max,
        input: maxTextTokenLogProbInputDescriptor,
        output: maxTextTokenLogProb,
        weights: nil
      )

      guard let timestampLogProbValue = timestampLogProb.makeArray(of: FloatType.self)?.first,
            let maxTextTokenLogProbValue = maxTextTokenLogProb.makeArray(of: FloatType.self)?.first
      else { return false }
      return timestampLogProbValue > maxTextTokenLogProbValue
    } catch {
      return false
    }
  }
}
