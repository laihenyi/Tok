//
//  PunctuationTests.swift
//  HexTests
//
//  Tests for segment-pause punctuation: syntax-aware placement,
//  adaptive thresholds, clause-marker word list, and normalization.
//

import CoreML
import Foundation
@testable import Tok
import Testing
import WhisperKit

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

  /// 坦白說/老實說 are discourse openers too. Real case 2026-07-04:
  /// 「非常的炎熱」|「坦白說」 gap 0.00 must not fuse into 「炎熱坦白說」.
  @Test
  func discourseOpenerTanbaishuo_getsCommaBeforeIt() {
    let segments = [
      TranscriptionSegment(text: "非常的炎熱", start: 2.0, end: 4.0),
      TranscriptionSegment(text: "坦白說", start: 4.0, end: 6.0),
      TranscriptionSegment(text: "不太適合在戶外走動", start: 6.0, end: 8.0),
    ]
    let output = client.punctuatedText(from: segments)
    #expect(output.contains("炎熱，坦白說"))
  }

  /// A segment starting with imperative 請 opens a new clause
  /// (…不太適合在戶外走動，請注意安全), but mid-phrase VAD splits like
  /// 請注意|安全 must stay untouched.
  @Test
  func imperativeQingAtSegmentStart_getsCommaBeforeIt() {
    let segments = [
      TranscriptionSegment(text: "不太適合在戶外走動", start: 6.0, end: 8.0),
      TranscriptionSegment(text: "請注意", start: 8.0, end: 10.0),
      TranscriptionSegment(text: "安全", start: 10.0, end: 12.0),
    ]
    let output = client.punctuatedText(from: segments)
    #expect(output == "不太適合在戶外走動，請注意安全。")
  }

  // MARK: - MOE punctuation rules (教育部《重訂標點符號手冊》)

  /// 間接問句用句號：疑問詞只是陳述句的一部分時（我不知道他去哪裡），
  /// 整句是陳述語氣，句末用句號不用問號。
  @Test
  func indirectQuestion_endsWithPeriodNotQuestionMark() {
    let output = client.normalizePunctuation("我不知道他去哪裡")
    #expect(output == "我不知道他去哪裡。")
  }

  /// 直接疑問句仍用問號——間接問句防護不可誤殺直接發問。
  @Test
  func directQuestion_stillGetsQuestionMark() {
    let output = client.normalizePunctuation("你要去哪裡")
    #expect(output == "你要去哪裡？")
  }

  /// 反問句用問號（MOE：你不肯，難道我肯？）
  @Test
  func rhetoricalQuestion_getsQuestionMark() {
    let output = client.normalizePunctuation("難道我會忘記你的生日")
    #expect(output == "難道我會忘記你的生日？")
  }

  /// 選擇問句只在句末用問號：選項間的停頓用逗號，
  /// 不可切成「星期六。還是星期日？」
  @Test
  func choiceQuestionAcrossSegments_usesCommaBeforeHaishi() {
    let segments = [
      TranscriptionSegment(text: "今天是星期六", start: 0.0, end: 2.0),
      TranscriptionSegment(text: "還是星期日", start: 3.0, end: 5.0),
    ]
    let output = client.punctuatedText(from: segments)
    #expect(output == "今天是星期六，還是星期日？")
  }

  /// 頓號不與連接詞並用：蘋果、香蕉和橘子（不是「香蕉、和橘子」）
  @Test
  func enumerationBeforeCoordinatingConjunction_getsNoDunhao() {
    let segments = [
      TranscriptionSegment(text: "蘋果", start: 0.0, end: 1.0),
      TranscriptionSegment(text: "香蕉", start: 1.2, end: 2.0),
      TranscriptionSegment(text: "和橘子", start: 2.2, end: 3.0),
    ]
    let output = client.punctuatedText(from: segments)
    #expect(output == "蘋果、香蕉和橘子。")
  }

  /// 感嘆句用驚嘆號（MOE：好大的雨啊！）——程度副詞＋句末語氣詞啊/呀
  @Test
  func exclamatorySentenceWithDegreeAdverb_getsExclamationMark() {
    let output = client.normalizePunctuation("好大的雨啊")
    #expect(output == "好大的雨啊！")
  }

  // MARK: - Model-level punctuation primer

  /// 中文標點風格引導 prompt：必須涵蓋常用標點，decoder 才會延續該風格
  /// 自行輸出標點。但不得含「：」——實測 2026-07-04 primer 帶冒號時，
  /// 模型把冒號當子句分隔符（今天艷陽高照：氣溫非常高：…）。
  @Test
  func punctuationPrimer_forChinese_containsFullPunctuationSet() throws {
    let primer = try #require(TranscriptionFeature.punctuationPrimer(forNormalizedLanguage: "zh"))
    for mark in ["，", "。", "？", "！", "、"] {
      #expect(primer.contains(mark))
    }
    #expect(!primer.contains("："))
  }

  /// 非中文或自動偵測（nil）不加中文引導——避免把其他語言的音訊
  /// 偏向中文輸出。
  @Test
  func punctuationPrimer_forNonChineseOrAutoDetect_isNil() {
    #expect(TranscriptionFeature.punctuationPrimer(forNormalizedLanguage: "en") == nil)
    #expect(TranscriptionFeature.punctuationPrimer(forNormalizedLanguage: nil) == nil)
  }

  /// WhisperKit 0.18：帶 promptTokens 時 prefill cache 被停用，decode loop
  /// 從 <|startofprev|> 開始，第一個取樣 token 的 logprob 天生偏低，
  /// 預設 firstTokenLogProbThreshold(-1.5) 會直接砍掉整段輸出（空字串）。
  /// 套用 promptTokens 時必須同時停用該閾值。
  @Test
  func applyingPromptTokens_disablesFirstTokenLogProbThreshold() {
    let base = DecodingOptions(language: "zh", chunkingStrategy: .vad)
    #expect(base.firstTokenLogProbThreshold != nil)

    let applied = TranscriptionFeature.applyingPromptTokens([1, 2, 3], to: base)
    #expect(applied.promptTokens == [1, 2, 3])
    #expect(applied.firstTokenLogProbThreshold == nil)
    // 其餘設定不可被動到
    #expect(applied.language == "zh")
  }

  /// 帶 prompt 解碼在段落邊界會走 byte 路徑輸出全形亂碼（Ｂ＝EF BC A2、
  /// ６＝EF BC 96，與全形標點，＝EF BC 8C 同字首；實測 2026-07-04 詩句間
  /// 反覆出現 [171,120,95] byte 序列）。壓制 EF 字首 byte token 171 封死
  /// byte 逃生路徑——常用全形標點都有單一 token，不受影響。
  @Test
  func applyingPromptTokens_suppressesFullwidthByteFallback() {
    let base = DecodingOptions(language: "zh", chunkingStrategy: .vad)
    let applied = TranscriptionFeature.applyingPromptTokens([1, 2, 3], to: base)
    #expect(applied.supressTokens.contains(171))
  }

  /// WhisperKit 0.18 的 decode loop 在 prefill（強制餵入 prompt）期間仍會
  /// 取樣，一旦 argmax 取到 <|endoftext|> 就把整個 window 中止成空字串
  /// （實測 2026-07-04：tokenIndex 51 取到 EOT，prefill 需 88 步）。
  /// 此 filter 必須在 prefill 期間把 EOT logit 壓成 -inf，
  /// prefill 結束後不得再干預。
  @Test
  func prefillEOTSuppression_masksEOTOnlyDuringPrefill() throws {
    let eot = 5, sot = 6
    let filter = PrefillEOTSuppressionFilter(endToken: eot, startOfTranscriptToken: sot)

    func makeLogits() throws -> MLMultiArray {
      let logits = try MLMultiArray(shape: [1, 1, 10], dataType: .float16)
      for i in 0..<10 { logits[[0, 0, i] as [NSNumber]] = 0 }
      return logits
    }
    func eotValue(_ logits: MLMultiArray) -> Float {
      logits[[0, 0, eot] as [NSNumber]].floatValue
    }

    // Prefill：tokens = [startofprev, prompt…, SOT, lang, task, timestamp]，
    // 長度在 prefill 期間固定為 sotIndex + 4 → 必須壓制 EOT
    let prefillTokens = [7, 1, 2, 3, sot, 8, 9, 4]
    let masked = filter.filterLogits(try makeLogits(), withTokens: prefillTokens)
    #expect(eotValue(masked) == -.infinity)

    // Prefill 結束（已取樣出第一個實際 token）→ 不得干預
    let sampling = filter.filterLogits(try makeLogits(), withTokens: prefillTokens + [42])
    #expect(eotValue(sampling) == 0)

    // 防禦：tokens 中沒有 SOT → 不得干預
    let noSOT = filter.filterLogits(try makeLogits(), withTokens: [7, 1, 2, 3])
    #expect(eotValue(noSOT) == 0)
  }

  /// WhisperKit 0.18 的 TimestampRulesFilter 只在 tokens.prefix(3) 找 task
  /// token，帶 promptTokens 時 task token 在第 85 位 → 整個 filter 失效，
  /// 「timestamp 機率總和高於任何文字 token 就強制輸出 timestamp」的規則
  /// 消失，段落邊界處 greedy 取樣滑到全形亂碼（實測 2026-07-04：詩句間
  /// 輸出Ｂ＝EF BC A2，正是全形標點的 byte 字首家族）。
  /// 修正版 filter 只在帶 prompt（tokens 以 <|startofprev|> 開頭）時啟動。
  @Test
  func promptTimestampRules_appliesOnlyWithPromptPrefix() throws {
    // Fake vocab layout: text 0–9, endToken 10, noTimestamps 11,
    // timestamps 12–19. Prompt-only values (never used as indices): 100/101.
    let filter = PromptTimestampRulesFilter(
      timeTokenBegin: 12, endToken: 10, noTimestampsToken: 11,
      startOfPreviousToken: 100, startOfTranscriptToken: 101
    )

    func makeLogits() throws -> MLMultiArray {
      let logits = try MLMultiArray(shape: [1, 1, 20], dataType: .float16)
      for i in 0..<20 { logits[[0, 0, i] as [NSNumber]] = 0 }
      // 讓文字 token 與 endToken 明顯勝出，避免「timestamp 機率總和」
      // 規則在假 logits 上誤觸發，聚焦測試成對規則本身
      logits[[0, 0, 1] as [NSNumber]] = 20
      logits[[0, 0, 10] as [NSNumber]] = 20
      return logits
    }
    func value(_ logits: MLMultiArray, _ i: Int) -> Float {
      logits[[0, 0, i] as [NSNumber]].floatValue
    }

    // prompt 前綴：[startofprev, prompt…, SOT, lang, task, ts] → 取樣區從 index 8 起
    let prefix = [100, 1, 2, 3, 101, 5, 6, 12]

    // 無 <|startofprev|>（一般解碼）→ 完全不干預，交給內建 filter
    let dormant = filter.filterLogits(try makeLogits(), withTokens: [101, 5, 6, 12])
    #expect(value(dormant, 11) == 0)

    // 帶 prompt、取樣中 → 必須壓制 <|notimestamps|>
    let active = filter.filterLogits(try makeLogits(), withTokens: prefix)
    #expect(value(active, 11) == -.infinity)

    // 剛輸出一個 timestamp（未成對）→ 文字 token 全部壓制，逼出成對 timestamp
    let pairing = filter.filterLogits(try makeLogits(), withTokens: prefix + [5, 13])
    #expect(value(pairing, 1) == -.infinity)
    #expect(value(pairing, 10) == 20) // endToken 例外：timestamp 後可直接結束

    // timestamp 已成對 → 換文字 token，timestamp 區壓制
    let paired = filter.filterLogits(try makeLogits(), withTokens: prefix + [13, 13])
    #expect(value(paired, 13) == -.infinity)
    #expect(value(paired, 1) == 20)
  }

  /// Window 邊界截斷的 byte token 會解碼成 U+FFFD（�）殘留在輸出
  ///（實測 2026-07-04：「低頭思故鄉�。」）。normalizePunctuation 是
  /// 兩條輸出路徑的共同終點，必須在此清除。
  @Test
  func normalizePunctuation_stripsReplacementCharacter() {
    let output = client.normalizePunctuation("低頭思故鄉\u{FFFD}")
    #expect(output == "低頭思故鄉。")
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
