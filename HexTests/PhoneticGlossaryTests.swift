//
//  PhoneticGlossaryTests.swift
//  HexTests
//
//  Tests for the phonetic glossary corrector: whole-glossary homophone
//  correction without consuming Whisper prompt-token budget.
//

import Foundation
@testable import Tok
import Testing

struct PhoneticGlossaryTests {
  /// 同音異字誤認（當責→當則、燈塔→登塔）必須被改回標準詞。
  @Test
  func homophoneVariant_isCorrectedToGlossaryTerm() {
    let glossary = PhoneticGlossary(terms: ["當責", "燈塔學校"])
    #expect(glossary.correct("我們強調當則的文化") == "我們強調當責的文化")
    #expect(glossary.correct("登塔學校很棒") == "燈塔學校很棒")
  }

  /// 已是標準詞或發音不同的內容不得被動到。
  @Test
  func correctOrUnrelatedText_isUntouched() {
    let glossary = PhoneticGlossary(terms: ["當責", "燈塔學校"])
    #expect(glossary.correct("當責文化很重要") == "當責文化很重要")
    #expect(glossary.correct("今天天氣很好") == "今天天氣很好")
  }

  /// 混雜數字／英文的文本要安全跳過非中文字。
  @Test
  func mixedNonCJKText_isSafe() {
    let glossary = PhoneticGlossary(terms: ["當責"])
    #expect(glossary.correct("7個習慣的當則精神") == "7個習慣的當責精神")
    #expect(glossary.correct("OK，沒問題。") == "OK，沒問題。")
  }

  /// 多個詞彙、長詞優先：較長的標準詞先匹配，不被短詞攔截。
  @Test
  func longerTermWins_whenOverlapping() {
    let glossary = PhoneticGlossary(terms: ["燈塔", "燈塔學校"])
    #expect(glossary.correct("登塔學校在山上") == "燈塔學校在山上")
  }
}
