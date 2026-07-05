//
//  PhoneticGlossary.swift
//  Hex
//
//  Whole-glossary homophone correction for transcription output.
//
//  Whisper's prompt window caps prompt-word biasing at ~35–40 Chinese words,
//  but domain glossaries run to hundreds of terms. Misrecognitions of known
//  terms are overwhelmingly homophone-class (當責→當則, 燈塔→登塔), so a
//  pronunciation-indexed dictionary can repair them AFTER transcription with
//  no prompt-token cost: any span of the output that sounds identical to a
//  glossary term but is written differently is rewritten to the standard
//  form. Pinyin comes from CFStringTransform (built into macOS, no
//  dependencies); keys are tone-stripped for recall since mishears often
//  drift in tone.
//
//  Terms are indexed per-character (not whole-string) so scan-time and
//  index-time readings of polyphonic characters agree. Keys shared by two
//  different glossary terms are dropped as ambiguous.
//

import Foundation

struct PhoneticGlossary: Sendable {
  /// pinyin key → canonical term (keys colliding across different terms are dropped)
  private let termsByKey: [String: String]
  /// Distinct term lengths in characters, longest first so longer terms win
  private let lengths: [Int]

  init(terms: [String]) {
    var index: [String: String] = [:]
    var ambiguous: Set<String> = []
    var lengthSet: Set<Int> = []

    for term in terms {
      let chars = Array(term)
      guard chars.count >= 2, chars.allSatisfy(\.isChineseCharacter) else { continue }
      let key = chars.map { Self.pinyinKey(String($0)) }.joined()
      guard !key.isEmpty else { continue }
      if let existing = index[key], existing != term {
        ambiguous.insert(key)
        continue
      }
      index[key] = term
      lengthSet.insert(chars.count)
    }
    for key in ambiguous { index.removeValue(forKey: key) }

    self.termsByKey = index
    self.lengths = lengthSet.sorted(by: >)
  }

  var isEmpty: Bool { termsByKey.isEmpty }

  /// Rewrites spans that sound identical to a glossary term (but are written
  /// differently) to the term's standard form. Non-Chinese characters are
  /// never part of a match window.
  func correct(_ text: String) -> String {
    guard !termsByKey.isEmpty, !text.isEmpty else { return text }

    var chars = Array(text)
    // Per-character pinyin, computed once ("" for non-Chinese characters)
    let keys: [String] = chars.map { $0.isChineseCharacter ? Self.pinyinKey(String($0)) : "" }

    var i = 0
    while i < chars.count {
      guard !keys[i].isEmpty else { i += 1; continue }
      var advance = 1
      for len in lengths where i + len <= chars.count {
        let windowKeys = keys[i..<(i + len)]
        guard !windowKeys.contains("") else { continue }
        guard let term = termsByKey[windowKeys.joined()] else { continue }
        let termChars = Array(term)
        if chars[i..<(i + len)] != termChars[...] {
          chars.replaceSubrange(i..<(i + len), with: termChars)
          #if DEBUG
          TranscriptionClientLive.appendDiagnostic("[Glossary] →\(term)\n")
          #endif
        }
        advance = len
        break
      }
      i += advance
    }
    return String(chars)
  }

  /// Tone-stripped pinyin for a single character via CFStringTransform.
  /// Per-character (context-free) so index and scan readings always agree.
  static func pinyinKey(_ text: String) -> String {
    let mutable = NSMutableString(string: text)
    CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
    return (mutable as String).replacingOccurrences(of: " ", with: "").lowercased()
  }
}

// MARK: - Cache for TranscriptionClient

/// Cache keyed on the glossary file's modification date — index construction
/// runs one CFStringTransform per character, so rebuild only on file change.
private var cachedPhoneticGlossary: PhoneticGlossary? = nil
private var cachedGlossaryMTime: Date? = .distantPast

/// Loads the standard-term glossary from ~/Documents/hex_phonetic_glossary.json
/// (a JSON array of Traditional Chinese terms). Returns an empty glossary if
/// the file is absent — correction then becomes a no-op.
func getCachedPhoneticGlossary() -> PhoneticGlossary {
  let url = URL.documentsDirectory.appending(component: "hex_phonetic_glossary.json")
  let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
  if let cached = cachedPhoneticGlossary, cachedGlossaryMTime == mtime {
    return cached
  }
  let terms = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? []
  let glossary = PhoneticGlossary(terms: terms)
  cachedPhoneticGlossary = glossary
  cachedGlossaryMTime = mtime
  return glossary
}

// MARK: - Character helper

private extension Character {
  var isChineseCharacter: Bool {
    guard let scalar = unicodeScalars.first else { return false }
    return (0x4E00...0x9FFF).contains(scalar.value) ||   // CJK Unified Ideographs
      (0x3400...0x4DBF).contains(scalar.value) ||        // CJK Extension A
      (0x20000...0x2A6DF).contains(scalar.value)         // CJK Extension B
  }
}
