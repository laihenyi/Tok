//
//  TextProcessorTests.swift
//  HexTests
//
//  Tests for smart text processing (filler removal + self-correction).
//  Guards against correction signals destroying ordinary sentences.
//

import Foundation
@testable import Tok
import Testing

struct TextProcessorTests {
  let processor = TextProcessor()
  let options = TextProcessingOptions(
    removeFillers: true, resolveSelfCorrections: true, detectedLanguage: "zh"
  )

  /// 「應該是」是推測語氣（epistemic marker），不是自我修正訊號。
  /// 實測 2026-07-04：使用者說「應該是吧?」輸出只剩「吧?」。
  @Test
  func epistemicYingGaiShi_isNotACorrectionSignal() {
    #expect(processor.process("應該是吧?", options: options) == "應該是吧?")
    #expect(processor.process("今天應該是星期五。", options: options) == "今天應該是星期五。")
  }

  /// 子句中間的「不是」是否定詞，不是修正訊號——沒有前置停頓
  /// 不得觸發修正解析（否則「我不是故意的」→「故意的」，語意反轉）。
  @Test
  func negationBuShi_midClause_isPreserved() {
    #expect(processor.process("我不是故意的。", options: options) == "我不是故意的。")
    #expect(processor.process("這不是問題。", options: options) == "這不是問題。")
  }

  /// 有前置停頓（逗號／空白）的修正訊號仍須正常解析。
  @Test
  func pauseDelimitedCorrection_stillResolves() {
    #expect(processor.process("五百塊 不是 三百塊", options: options) == "三百塊")
    #expect(processor.process("去台北，不對，去台南。", options: options) == "去台南。")
  }

  /// 修正訊號位於子句開頭（前面是句號或字串開頭）也要解析——
  /// 只丟掉訊號詞本身。
  @Test
  func clauseInitialCorrectionSignal_dropsSignalOnly() {
    #expect(processor.process("不對，去台南。", options: options) == "去台南。")
  }

  /// 明確修正片語（我是說）維持既有行為。
  @Test
  func explicitCorrectionPhrase_stillResolves() {
    #expect(processor.process("我要去台北，我是說，台南。", options: options) == "台南。")
  }

  /// 「基本上」是承載立場的語氣開頭詞（標點系統的 discourseOpener），
  /// 不是無意義填充詞。模型現在會在它後面自動標逗號，若留在填充詞
  /// 清單裡就每次必刪（實測 2026-07-04：「基本上，我同意你的看法」
  /// 輸出遺失「基本上」）。真填充詞（嗯／那個／就是說）維持移除。
  @Test
  func discourseOpenerJiBenShang_isNotRemovedAsFiller() {
    #expect(processor.process("基本上，我同意你的看法。", options: options) == "基本上，我同意你的看法。")
    // 真填充詞仍要移除
    #expect(processor.process("嗯，那個，我們開始吧。", options: options) == "我們開始吧。")
  }
}
