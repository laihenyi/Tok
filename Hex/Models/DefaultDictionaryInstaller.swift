//
//  DefaultDictionaryInstaller.swift
//  Hex
//
//  First-launch seeding of the bundled default dictionaries. The app ships
//  with an education-domain vocabulary (custom words for Whisper biasing +
//  the phonetic standard-term glossary); on launch each file is copied to
//  ~/Documents only if the user doesn't already have one — existing user
//  dictionaries are never touched.
//

import Foundation

enum DefaultDictionaryInstaller {
  /// Copies the bundled resource to `destination` unless a file already
  /// exists there. Returns true only when an installation happened.
  @discardableResult
  static func installIfMissing(
    resource: String,
    to destination: URL,
    bundle: Bundle = .main
  ) -> Bool {
    guard !FileManager.default.fileExists(atPath: destination.path),
          let source = bundle.url(forResource: resource, withExtension: "json")
    else { return false }
    do {
      try FileManager.default.copyItem(at: source, to: destination)
      print("[DefaultDictionaryInstaller] Installed \(resource) → \(destination.lastPathComponent)")
      return true
    } catch {
      print("[DefaultDictionaryInstaller] Failed to install \(resource): \(error)")
      return false
    }
  }

  /// Seeds both dictionaries on first launch.
  static func installDefaults() {
    let documents = URL.documentsDirectory
    installIfMissing(resource: "DefaultCustomWords",
                     to: documents.appending(component: "hex_custom_words.json"))
    installIfMissing(resource: "DefaultPhoneticGlossary",
                     to: documents.appending(component: "hex_phonetic_glossary.json"))
  }
}
