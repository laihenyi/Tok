//
//  DefaultDictionaryInstallerTests.swift
//  HexTests
//
//  Tests for first-launch installation of bundled default dictionaries.
//

import Foundation
@testable import Tok
import Testing

struct DefaultDictionaryInstallerTests {
  /// 目的地不存在 → 從 bundle 安裝預設字典檔。
  @Test
  func missingDestination_installsBundledDefault() throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(component: "installer-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let dest = dir.appending(component: "hex_phonetic_glossary.json")

    let installed = DefaultDictionaryInstaller.installIfMissing(
      resource: "DefaultPhoneticGlossary", to: dest)

    #expect(installed)
    let terms = try JSONDecoder().decode([String].self, from: Data(contentsOf: dest))
    #expect(terms.count > 400) // 教育領域標準詞庫
  }

  /// 目的地已存在（使用者自己的字典）→ 絕不覆蓋。
  @Test
  func existingDestination_isNeverOverwritten() throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(component: "installer-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let dest = dir.appending(component: "hex_phonetic_glossary.json")
    try Data("[\"使用者自訂\"]".utf8).write(to: dest)

    let installed = DefaultDictionaryInstaller.installIfMissing(
      resource: "DefaultPhoneticGlossary", to: dest)

    #expect(!installed)
    let terms = try JSONDecoder().decode([String].self, from: Data(contentsOf: dest))
    #expect(terms == ["使用者自訂"])
  }

  /// 內建的預設自訂詞庫必須是可解碼的 CustomWordDictionary。
  @Test
  func bundledCustomWords_decodeAsValidDictionary() throws {
    let url = try #require(Bundle.main.url(forResource: "DefaultCustomWords", withExtension: "json"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    let dictionary = try decoder.decode(CustomWordDictionary.self, from: Data(contentsOf: url))
    #expect(dictionary.isEnabled)
    #expect(!dictionary.enabledPromptEntries.isEmpty)
    #expect(!dictionary.enabledReplacementEntries.isEmpty)
  }
}
