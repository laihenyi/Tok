import Foundation

// MARK: - Correction Record

/// A single correction record with occurrence tracking
struct CorrectionRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let original: String
    let corrected: String
    var occurrenceCount: Int
    let firstOccurrence: Date
    var lastOccurrence: Date

    /// Whether this correction should be suggested for auto-learning
    var shouldSuggestForLearning: Bool {
        occurrenceCount >= CorrectionHistory.learningThreshold
    }

    /// Whether this correction has been added to the dictionary
    var addedToDictionary: Bool = false

    init(original: String, corrected: String) {
        self.id = UUID()
        self.original = original
        self.corrected = corrected
        self.occurrenceCount = 1
        self.firstOccurrence = Date()
        self.lastOccurrence = Date()
    }
}

// MARK: - Correction History

/// Manages the history of user corrections for learning
final class CorrectionHistory: ObservableObject {

    // MARK: - Constants

    /// Number of times a correction must occur before suggesting to add to dictionary
    static let learningThreshold = 2

    /// File name for storing correction history
    private static let fileName = "correction_history.json"

    // MARK: - Properties

    @Published private(set) var records: [CorrectionRecord] = []

    private let diffTracker = DiffTracker()
    private let fileURL: URL

    // MARK: - Singleton

    static let shared = CorrectionHistory()

    // MARK: - Initialization

    private init() {
        fileURL = URL.documentsDirectory.appending(component: Self.fileName)
        loadHistory()
    }

    // MARK: - Public Methods

    /// Record a correction from user editing
    func recordCorrection(original: String, edited: String) {
        guard original != edited else { return }

        // Find the specific corrections
        let (corrections, phrases) = diffTracker.analyzeCorrection(original: original, edited: edited)

        // Record each correction
        for correction in corrections {
            addOrUpdateRecord(original: correction.original, corrected: correction.corrected)
        }

        // Also record expanded phrases
        for phrase in phrases {
            addOrUpdateRecord(original: phrase.original, corrected: phrase.corrected)
        }

        saveHistory()
    }

    /// Get corrections that are ready for learning (occurred enough times)
    func getCorrectionsReadyForLearning() -> [CorrectionRecord] {
        records.filter { $0.shouldSuggestForLearning && !$0.addedToDictionary }
    }

    /// Mark a correction as added to dictionary
    func markAsAddedToDictionary(_ record: CorrectionRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index].addedToDictionary = true
            saveHistory()
        }
    }

    /// Remove a correction record
    func removeRecord(_ record: CorrectionRecord) {
        records.removeAll { $0.id == record.id }
        saveHistory()
    }

    /// Clear all history
    func clearHistory() {
        records = []
        saveHistory()
    }

    // MARK: - Private Methods

    private func addOrUpdateRecord(original: String, corrected: String) {
        // Check if this correction already exists
        if let index = records.firstIndex(where: { $0.original == original && $0.corrected == corrected }) {
            // Update existing record
            records[index].occurrenceCount += 1
            records[index].lastOccurrence = Date()

            print("[CorrectionHistory] Updated: '\(original)' → '\(corrected)' (count: \(records[index].occurrenceCount))")

            // Check if ready for learning
            if records[index].shouldSuggestForLearning && !records[index].addedToDictionary {
                notifyReadyForLearning(records[index])
            }
        } else {
            // Add new record
            let record = CorrectionRecord(original: original, corrected: corrected)
            records.append(record)

            print("[CorrectionHistory] New correction: '\(original)' → '\(corrected)'")
        }
    }

    private func notifyReadyForLearning(_ record: CorrectionRecord) {
        print("[CorrectionHistory] Ready for learning: '\(record.original)' → '\(record.corrected)' (occurred \(record.occurrenceCount) times)")

        // Post notification for UI to show suggestion
        NotificationCenter.default.post(
            name: .correctionReadyForLearning,
            object: nil,
            userInfo: ["record": record]
        )
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[CorrectionHistory] No history file found, starting fresh")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([CorrectionRecord].self, from: data)
            print("[CorrectionHistory] Loaded \(records.count) correction records")
        } catch {
            print("[CorrectionHistory] Error loading history: \(error)")
        }
    }

    private func saveHistory() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: fileURL)
            print("[CorrectionHistory] Saved \(records.count) correction records")
        } catch {
            print("[CorrectionHistory] Error saving history: \(error)")
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let correctionReadyForLearning = Notification.Name("correctionReadyForLearning")
}

// MARK: - Auto Learning Manager

/// Manages automatic learning from corrections
final class AutoLearningManager {

    static let shared = AutoLearningManager()

    private let correctionHistory = CorrectionHistory.shared

    private init() {
        setupNotifications()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCorrectionReady(_:)),
            name: .correctionReadyForLearning,
            object: nil
        )
    }

    @objc private func handleCorrectionReady(_ notification: Notification) {
        guard let record = notification.userInfo?["record"] as? CorrectionRecord else { return }

        // Auto-add to dictionary
        addToDictionary(record)
    }

    /// Add a correction to the custom word dictionary
    func addToDictionary(_ record: CorrectionRecord) {
        // Load current dictionary
        let dictionaryURL = URL.documentsDirectory.appending(component: "hex_custom_words.json")

        do {
            var dictionary: CustomWordDictionary

            if FileManager.default.fileExists(atPath: dictionaryURL.path) {
                let data = try Data(contentsOf: dictionaryURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                dictionary = try decoder.decode(CustomWordDictionary.self, from: data)
            } else {
                dictionary = CustomWordDictionary()
            }

            // Check if entry already exists
            let exists = dictionary.entries.contains {
                $0.original == record.original && $0.replacement == record.corrected
            }

            guard !exists else {
                print("[AutoLearning] Entry already exists: '\(record.original)' → '\(record.corrected)'")
                correctionHistory.markAsAddedToDictionary(record)
                return
            }

            // Add new entry
            let newEntry = CustomWordEntry(
                original: record.original,
                replacement: record.corrected,
                isEnabled: true,
                caseSensitive: false,
                source: .learned,
                entryType: .replacement
            )

            dictionary.entries.append(newEntry)
            dictionary.lastModified = Date()

            // Save dictionary
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(dictionary)
            try data.write(to: dictionaryURL)

            // Mark as added
            correctionHistory.markAsAddedToDictionary(record)

            // Invalidate cache
            invalidateCustomWordDictionaryCache()

            print("[AutoLearning] Added to dictionary: '\(record.original)' → '\(record.corrected)'")

            // Post notification for UI feedback
            NotificationCenter.default.post(
                name: .wordAddedToDictionary,
                object: nil,
                userInfo: ["original": record.original, "corrected": record.corrected]
            )

        } catch {
            print("[AutoLearning] Error adding to dictionary: \(error)")
        }
    }
}

// MARK: - Additional Notification Names

extension Notification.Name {
    static let wordAddedToDictionary = Notification.Name("wordAddedToDictionary")
}
