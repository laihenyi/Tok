//
//  CustomWordDictionary.swift
//  Hex
//
//  Custom word replacement dictionary for improving transcription accuracy
//

import ComposableArchitecture
import Foundation

/// A single word entry - can be either a prompt word or replacement rule
struct CustomWordEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var original: String       // For prompt: the word itself; For replacement: text to replace (e.g., "台灣")
    var replacement: String    // For prompt: same as original; For replacement: target text (e.g., "臺灣")
    var isEnabled: Bool = true
    var caseSensitive: Bool = false
    var createdAt: Date = Date()
    var source: EntrySource = .manual
    var entryType: EntryType = .replacement  // New: distinguish between prompt and replacement

    enum EntrySource: String, Codable, Equatable {
        case manual = "manual"           // Manually added by user
        case imported = "imported"       // Imported from external source
        case naturalInput = "naturalInput" // Imported from 自然輸入法
        case learned = "learned"         // Auto-learned from user corrections
    }

    /// Type of entry - prompt words influence recognition, replacements fix output
    enum EntryType: String, Codable, Equatable {
        case prompt = "prompt"           // 提示詞：引導 Whisper 在辨識時傾向輸出這個詞
        case replacement = "replacement" // 替換詞：在辨識結果中將 original 替換為 replacement
    }

    // Custom Codable to handle missing entryType field (for backwards compatibility)
    enum CodingKeys: String, CodingKey {
        case id, original, replacement, isEnabled, caseSensitive, createdAt, source, entryType
    }

    init(
        id: UUID = UUID(),
        original: String,
        replacement: String,
        isEnabled: Bool = true,
        caseSensitive: Bool = false,
        createdAt: Date = Date(),
        source: EntrySource = .manual,
        entryType: EntryType = .replacement
    ) {
        self.id = id
        self.original = original
        self.replacement = replacement
        self.isEnabled = isEnabled
        self.caseSensitive = caseSensitive
        self.createdAt = createdAt
        self.source = source
        self.entryType = entryType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        original = try container.decode(String.self, forKey: .original)
        replacement = try container.decode(String.self, forKey: .replacement)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false

        // Handle createdAt which can be Date, ISO8601 string, or missing
        if let dateValue = try? container.decodeIfPresent(Date.self, forKey: .createdAt) {
            createdAt = dateValue
        } else if let dateString = try? container.decodeIfPresent(String.self, forKey: .createdAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                createdAt = date
            } else {
                // Try without fractional seconds
                formatter.formatOptions = [.withInternetDateTime]
                createdAt = formatter.date(from: dateString) ?? Date()
            }
        } else {
            createdAt = Date()
        }

        source = try container.decodeIfPresent(EntrySource.self, forKey: .source) ?? .manual
        // Default to .replacement for backwards compatibility with existing entries
        entryType = try container.decodeIfPresent(EntryType.self, forKey: .entryType) ?? .replacement
    }

    /// Whether this is a prompt-type entry (affects transcription recognition)
    var isPromptEntry: Bool {
        entryType == .prompt
    }

    /// Whether this is a replacement-type entry (affects post-processing)
    var isReplacementEntry: Bool {
        entryType == .replacement
    }
}

/// The complete custom word dictionary
struct CustomWordDictionary: Codable, Equatable {
    var entries: [CustomWordEntry] = []
    var isEnabled: Bool = true  // Global toggle for the feature
    var lastModified: Date = Date()

    /// Get all enabled entries
    var enabledEntries: [CustomWordEntry] {
        guard isEnabled else { return [] }
        return entries.filter { $0.isEnabled }
    }

    /// Get enabled prompt entries (for Whisper prompt biasing)
    var enabledPromptEntries: [CustomWordEntry] {
        enabledEntries.filter { $0.isPromptEntry }
    }

    /// Get enabled replacement entries (for post-processing)
    var enabledReplacementEntries: [CustomWordEntry] {
        enabledEntries.filter { $0.isReplacementEntry }
    }

    /// Get prompt text for Whisper (combines all prompt words)
    /// Format: space-separated list of words to bias transcription
    var promptText: String {
        let words = enabledPromptEntries.map { $0.original }
        return words.joined(separator: " ")
    }

    /// Add a new entry, avoiding duplicates
    mutating func addEntry(_ entry: CustomWordEntry) {
        // Check for duplicate original text
        if !entries.contains(where: { $0.original == entry.original }) {
            entries.append(entry)
            lastModified = Date()
        }
    }

    /// Add multiple entries (for import)
    mutating func addEntries(_ newEntries: [CustomWordEntry]) {
        for entry in newEntries {
            addEntry(entry)
        }
    }

    /// Remove entry by ID
    mutating func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        lastModified = Date()
    }

    /// Update an existing entry
    mutating func updateEntry(_ entry: CustomWordEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            lastModified = Date()
        }
    }

    /// Apply word replacements to text (only processes replacement-type entries)
    func applyReplacements(to text: String) -> String {
        guard isEnabled, !entries.isEmpty, !text.isEmpty else {
            print("[CustomWordDictionary] Skipping replacements: isEnabled=\(isEnabled), entries=\(entries.count), textEmpty=\(text.isEmpty)")
            return text
        }

        var result = text
        let replacementEntries = enabledReplacementEntries
        print("[CustomWordDictionary] Applying \(replacementEntries.count) replacement rules to text: \(text.prefix(50))...")

        // Only apply replacement entries, not prompt entries
        for entry in replacementEntries {
            let options: String.CompareOptions = entry.caseSensitive ? [] : [.caseInsensitive]
            let before = result
            result = result.replacingOccurrences(
                of: entry.original,
                with: entry.replacement,
                options: options
            )
            if before != result {
                print("[CustomWordDictionary] Replaced '\(entry.original)' → '\(entry.replacement)'")
            }
        }

        if result != text {
            print("[CustomWordDictionary] Final result: \(result.prefix(100))...")
        }
        return result
    }
}

// MARK: - File Storage

extension SharedReaderKey where Self == FileStorageKey<CustomWordDictionary>.Default {
    static var customWordDictionary: Self {
        Self[
            .fileStorage(URL.documentsDirectory.appending(component: "hex_custom_words.json")),
            default: CustomWordDictionary()
        ]
    }
}

// MARK: - Import/Export Helpers

extension CustomWordDictionary {
    /// Export to JSON string
    func exportToJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Import from JSON string
    static func importFromJSON(_ jsonString: String) throws -> CustomWordDictionary {
        guard let data = jsonString.data(using: .utf8) else {
            throw ImportError.invalidData
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CustomWordDictionary.self, from: data)
    }

    /// Import from CSV string (format: original,replacement)
    static func importFromCSV(_ csvString: String) throws -> [CustomWordEntry] {
        var entries: [CustomWordEntry] = []
        let lines = csvString.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.components(separatedBy: ",")
            guard parts.count >= 2 else { continue }

            let original = parts[0].trimmingCharacters(in: .whitespaces)
            let replacement = parts[1].trimmingCharacters(in: .whitespaces)

            guard !original.isEmpty, !replacement.isEmpty else { continue }

            entries.append(CustomWordEntry(
                original: original,
                replacement: replacement,
                source: .imported
            ))
        }

        return entries
    }

    /// Export entries to CSV string
    func exportToCSV() -> String {
        var lines = ["# Custom Word Dictionary", "# Format: original,replacement"]
        for entry in entries {
            lines.append("\(entry.original),\(entry.replacement)")
        }
        return lines.joined(separator: "\n")
    }

    enum ImportError: Error, LocalizedError {
        case invalidData
        case invalidFormat
        case fileNotFound

        var errorDescription: String? {
            switch self {
            case .invalidData: return "Invalid data format"
            case .invalidFormat: return "Unsupported file format"
            case .fileNotFound: return "File not found"
            }
        }
    }
}

// MARK: - Natural Input Method Import

extension CustomWordDictionary {
    /// Import from 自然輸入法 profile.db
    /// This reads the local database and extracts high-frequency words
    static func importFromNaturalInputMethod(
        minimumHits: Int = 100,
        maxEntries: Int = 500
    ) throws -> [NaturalInputEntry] {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GOING11/UserData/Going11/profile.db")

        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            throw ImportError.fileNotFound
        }

        // Use SQLite to read the database
        return try NaturalInputDBReader.readEntries(
            from: dbPath,
            minimumHits: minimumHits,
            maxEntries: maxEntries
        )
    }
}

/// Entry from Natural Input Method database
struct NaturalInputEntry: Identifiable, Equatable {
    let id = UUID()
    let keystrokes: String  // Bopomofo keystrokes (e.g., "ㄊㄞˊ-ㄨㄢ")
    let pattern: String     // The word (e.g., "臺灣")
    let hits: Int           // Usage count

    /// Convert to CustomWordEntry with a replacement rule
    func toCustomWordEntry(replacingOriginal original: String) -> CustomWordEntry {
        CustomWordEntry(
            original: original,
            replacement: pattern,
            source: .naturalInput
        )
    }
}

/// SQLite reader for Natural Input Method database
enum NaturalInputDBReader {
    static func readEntries(
        from dbPath: URL,
        minimumHits: Int,
        maxEntries: Int
    ) throws -> [NaturalInputEntry] {
        var entries: [NaturalInputEntry] = []

        // Use sqlite3 command line tool to read the database
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            dbPath.path,
            "SELECT keystrokes, pattern, hits FROM profile WHERE hits >= \(minimumHits) ORDER BY hits DESC LIMIT \(maxEntries);"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return entries
        }

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 3,
                  let hits = Int(parts[2]) else { continue }

            entries.append(NaturalInputEntry(
                keystrokes: parts[0],
                pattern: parts[1],
                hits: hits
            ))
        }

        return entries
    }
}

// MARK: - Cache for TranscriptionClient

/// Cache for CustomWordDictionary to reduce disk I/O during transcription
private var cachedCustomWordDictionary: CustomWordDictionary? = nil
private var lastDictionaryLoadTime: Date = .distantPast

/// Helper function to get cached dictionary or load from disk
/// Used by TranscriptionClient for efficient word replacement during transcription
func getCachedCustomWordDictionary() -> CustomWordDictionary {
    // Use cached dictionary if it exists and is recent (within last 5 seconds)
    if let cached = cachedCustomWordDictionary,
       Date().timeIntervalSince(lastDictionaryLoadTime) < 5.0 {
        return cached
    }

    // Otherwise read from disk
    do {
        let url = URL.documentsDirectory.appending(component: "hex_custom_words.json")
        print("[CustomWordDictionary] Loading from: \(url.path)")
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let dictionary = try decoder.decode(CustomWordDictionary.self, from: data)
            print("[CustomWordDictionary] Loaded \(dictionary.entries.count) entries, \(dictionary.enabledReplacementEntries.count) replacement rules enabled")

            // Update cache
            cachedCustomWordDictionary = dictionary
            lastDictionaryLoadTime = Date()

            return dictionary
        } else {
            print("[CustomWordDictionary] File does not exist at path")
        }
    } catch {
        print("[CustomWordDictionary] Error loading: \(error)")
    }

    // On error or if file doesn't exist, return default empty dictionary
    print("[CustomWordDictionary] Returning empty default dictionary")
    let defaultDictionary = CustomWordDictionary()
    cachedCustomWordDictionary = defaultDictionary
    lastDictionaryLoadTime = Date()
    return defaultDictionary
}

/// Invalidate the cache when dictionary is modified
/// Call this after adding, removing, or updating entries
func invalidateCustomWordDictionaryCache() {
    cachedCustomWordDictionary = nil
    lastDictionaryLoadTime = .distantPast
}
