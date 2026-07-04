//
//  PunctuationTests.swift
//  HexTests
//
//  Tests for segment-pause punctuation: syntax-aware placement,
//  adaptive thresholds, clause-marker word list, and normalization.
//

import Foundation
@testable import Tok
import Testing

struct PunctuationTests {
  let client = TranscriptionClientLive()

  // MARK: - Target 1: Syntax-aware punctuation placement

  /// A pause right after a forward-binding connective (一旦/如果/但是…) is
  /// hesitation, not a clause boundary. Punctuation belongs BEFORE the
  /// connective, which binds to the following clause.
  @Test
  func pauseAfterConnective_relocatesPunctuationBeforeConnective() {
    let segments = [
      TranscriptionSegment(text: "真人口說的語速會有快有慢一旦", start: 0.0, end: 2.0),
      TranscriptionSegment(text: "如果說的比較慢系統會誤判", start: 2.5, end: 5.0),
    ]
    let output = client.punctuatedText(from: segments)
    #expect(!output.contains("一旦，"))
    #expect(output.contains("，一旦"))
  }

  /// A segment that consists solely of a connective followed by a pause
  /// gets no punctuation after it — the connective binds forward.
  @Test
  func connectiveOnlySegment_getsNoPunctuationAfterIt() {
    let segments = [
      TranscriptionSegment(text: "然後", start: 0.0, end: 0.5),
      TranscriptionSegment(text: "我們就回家了", start: 1.5, end: 3.0),
    ]
    let output = client.punctuatedText(from: segments)
    #expect(!output.contains("然後。"))
    #expect(!output.contains("然後，"))
  }

  // MARK: - Target 2: Adaptive pause thresholds

  /// Slow speakers pause longer everywhere. Uniform ~1s gaps are that
  /// speaker's normal rhythm, not sentence boundaries — they should become
  /// commas, not period fragments.
  @Test
  func slowSpeech_uniformLongGaps_doNotBecomePeriodFragments() {
    let segments = [
      TranscriptionSegment(text: "我今天早上去學校", start: 0.0, end: 2.0),
      TranscriptionSegment(text: "參加了一場重要的會議", start: 3.0, end: 5.0),
      TranscriptionSegment(text: "討論了很多事情", start: 6.0, end: 8.0),
      TranscriptionSegment(text: "接著就回家了", start: 9.0, end: 10.0),
    ]
    let output = client.punctuatedText(from: segments)
    let interiorPeriods = output.dropLast().filter { $0 == "。" }.count
    #expect(interiorPeriods == 0)
    #expect(output.contains("，"))
  }

  /// With too few gaps to establish a rhythm, absolute thresholds still
  /// apply: a clearly long pause remains a sentence boundary.
  @Test
  func normalSpeech_longPause_stillEndsSentence() {
    let segments = [
      TranscriptionSegment(text: "今天天氣很好", start: 0.0, end: 1.5),
      TranscriptionSegment(text: "我們出去玩吧", start: 2.5, end: 4.0),
    ]
    let output = client.punctuatedText(from: segments)
    #expect(output.contains("今天天氣很好。"))
  }

  // MARK: - Target 3: Clause-marker word list

  /// 否則/不然 are unambiguous clause starters and belong in the fallback list.
  @Test
  func fallbackInsertsCommaBeforeBuran() {
    let output = client.insertPunctuationAtClauseBoundaries("你要早點睡不然明天起不來")
    #expect(output == "你要早點睡，不然明天起不來")
  }

  /// 之前 is frequently postpositional (X之前 = "before X") — inserting a
  /// comma before it corrupts noun phrases like 我之前的老師.
  @Test
  func temporalMarkerInNounPhrase_isNotSplit() {
    let output = client.insertPunctuationAtClauseBoundaries("我之前的老師很好")
    #expect(output == "我之前的老師很好")
  }

  /// 現在的 is a noun-phrase modifier, not a clause boundary.
  @Test
  func temporalMarkerFollowedByDe_isNotSplit() {
    let output = client.insertPunctuationAtClauseBoundaries("我現在的工作很忙")
    #expect(output == "我現在的工作很忙")
  }

  /// A marker immediately following another connective (一旦如果) is one
  /// compound connective cluster — no comma inside it.
  @Test
  func markerFollowingAnotherConnective_isNotSplit() {
    let output = client.insertPunctuationAtClauseBoundaries("一旦如果說的比較慢就會誤判")
    #expect(!output.contains("一旦，如果"))
  }

  /// Genuine clause boundaries still get commas.
  @Test
  func fallbackStillInsertsCommaAtGenuineBoundaries() {
    let output = client.insertPunctuationAtClauseBoundaries("他很想去但是沒有時間")
    #expect(output == "他很想去，但是沒有時間")
  }

  /// Words like 在於/就是 cannot end a sentence — a long thinking pause
  /// after one demotes to a comma, never a period. Real case 2026-07-04:
  /// 「這次測試的重點在於」+ 3s pause → must NOT become 「在於。」.
  @Test
  func longPauseAfterNonFinalTail_becomesCommaNotPeriod() {
    let segments = [
      TranscriptionSegment(text: "這次測試的重點在於", start: 5.0, end: 7.0),
      TranscriptionSegment(text: "說話的斷點是否有準確標示", start: 10.0, end: 15.0),
    ]
    let output = client.punctuatedText(from: segments)
    #expect(!output.contains("在於。"))
    #expect(output.contains("在於，"))
  }

  /// A segment starting with a discourse opener (當然/其實…) marks a new
  /// clause even with zero gap — VAD split there is evidence enough.
  /// Real case 2026-07-04: 「讓身心靈都獲得均衡」+「當然如果…」 gap 0.00
  /// must not fuse into 「均衡當然」.
  @Test
  func discourseOpenerAtSegmentStart_getsCommaBeforeIt() {
    let segments = [
      TranscriptionSegment(text: "讓身心靈都獲得均衡", start: 0.0, end: 4.0),
      TranscriptionSegment(text: "當然如果你想要在家裡賴床", start: 4.0, end: 8.0),
    ]
    let output = client.punctuatedText(from: segments)
    #expect(output.contains("均衡，當然"))
  }

  // MARK: - Whisper special tokens

  /// Segment text arrives with raw Whisper tokens (<|zh|>, <|1.28|>…).
  /// They must be stripped BEFORE punctuation analysis — otherwise inserted
  /// marks land around the tokens and survive dedup as "。，" once the
  /// tokens are removed downstream. Reproduces a real transcription from
  /// 2026-07-04 testing.
  @Test
  func whisperSpecialTokens_doNotBreakPunctuationPlacement() {
    let segments = [
      TranscriptionSegment(
        text: "<|startoftranscript|><|zh|><|transcribe|><|1.28|>今天天氣很好<|3.32|>",
        start: 1.28, end: 3.32
      ),
      TranscriptionSegment(
        text: "<|4.60|>其實蠻適合出外踏青走一走的<|9.16|>",
        start: 4.60, end: 9.16
      ),
    ]
    let output = client.punctuatedText(from: segments)
    #expect(output == "今天天氣很好。其實蠻適合出外踏青走一走的。")
  }

  // MARK: - Target 4: Punctuation dedup across whitespace

  /// Whitespace between two punctuation marks must not defeat dedup:
  /// "。 ：" collapses to "。".
  @Test
  func consecutivePunctuationSeparatedByWhitespace_isDeduplicated() {
    let output = client.normalizePunctuation("很奇怪。 ：這是測試的結果")
    #expect(output == "很奇怪。這是測試的結果。")
  }

  /// Whitespace between ordinary characters is preserved.
  @Test
  func whitespaceBetweenWords_isPreserved() {
    let output = client.normalizePunctuation("今天 天氣很好")
    #expect(output == "今天 天氣很好。")
  }
}
