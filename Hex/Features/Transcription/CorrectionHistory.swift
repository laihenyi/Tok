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

    /// Record corrections identified by AI enhancement comparison
    func recordAICorrection(original: String, enhanced: String) {
        guard original != enhanced else { return }

        let aiCorrections = diffTracker.analyzeAICorrection(original: original, enhanced: enhanced)

        for correction in aiCorrections {
            addOrUpdateRecord(original: correction.original, corrected: correction.corrected)
        }

        if !aiCorrections.isEmpty {
            saveHistory()
        }
    }

    /// Get corrections that are ready for learning (occurred enough times)
    func getCorrectionsReadyForLearning() -> [CorrectionRecord] {
        records.filter { $0.shouldSuggestForLearning && !$0.addedToDictionary }
    }

    /// Process any pending corrections that are ready for learning
    /// Called at startup to catch any that were missed
    func processPendingLearning() {
        let pending = getCorrectionsReadyForLearning()
        for record in pending {
            notifyReadyForLearning(record)
        }
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
        if let index = records.firstIndex(where: { $0.original == original && $0.corrected == corrected }) {
            records[index].occurrenceCount += 1
            records[index].lastOccurrence = Date()
            if records[index].shouldSuggestForLearning && !records[index].addedToDictionary {
                notifyReadyForLearning(records[index])
            }
        } else {
            let record = CorrectionRecord(original: original, corrected: corrected)
            records.append(record)
        }
    }

    private func notifyReadyForLearning(_ record: CorrectionRecord) {
        NotificationCenter.default.post(
            name: .correctionReadyForLearning,
            object: nil,
            userInfo: [
                "id": record.id.uuidString,
                "original": record.original,
                "corrected": record.corrected
            ]
        )
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([CorrectionRecord].self, from: data)
        } catch {
            // Failed to load history - start fresh
        }
    }

    private func saveHistory() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: fileURL)
        } catch {
            // Failed to save history
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
        // Process any pending corrections that were missed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.processPendingCorrections()
        }
    }

    private func processPendingCorrections() {
        let pending = correctionHistory.getCorrectionsReadyForLearning()
        for record in pending {
            addToDictionary(record)
        }
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
        guard let idString = notification.userInfo?["id"] as? String,
              let id = UUID(uuidString: idString) else {
            return
        }
        if let record = correctionHistory.records.first(where: { $0.id == id }) {
            addToDictionary(record)
        }
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
                // Use deferredToDate to handle numeric timestamps (timeIntervalSinceReferenceDate)
                decoder.dateDecodingStrategy = .deferredToDate
                dictionary = try decoder.decode(CustomWordDictionary.self, from: data)
            } else {
                dictionary = CustomWordDictionary()
            }

            // Check if entry already exists
            let exists = dictionary.entries.contains {
                $0.original == record.original && $0.replacement == record.corrected
            }

            guard !exists else {
                correctionHistory.markAsAddedToDictionary(record)
                return
            }

            // Add replacement entry
            let replacementEntry = CustomWordEntry(
                original: record.original,
                replacement: record.corrected,
                isEnabled: true,
                caseSensitive: false,
                source: .learned,
                entryType: .replacement
            )
            dictionary.entries.append(replacementEntry)

            // Also add a prompt entry so WhisperKit recognizes the corrected form
            let promptExists = dictionary.entries.contains {
                $0.original == record.corrected && $0.entryType == .prompt
            }
            if !promptExists {
                let promptEntry = CustomWordEntry(
                    original: record.corrected,
                    replacement: "",
                    isEnabled: true,
                    caseSensitive: false,
                    source: .learned,
                    entryType: .prompt
                )
                dictionary.entries.append(promptEntry)
            }

            dictionary.lastModified = Date()

            // Save dictionary
            let encoder = JSONEncoder()
            // Use deferredToDate to match the existing file format
            encoder.dateEncodingStrategy = .deferredToDate
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(dictionary)
            try data.write(to: dictionaryURL)

            // Mark as added
            correctionHistory.markAsAddedToDictionary(record)

            invalidateCustomWordDictionaryCache()

            NotificationCenter.default.post(
                name: .wordAddedToDictionary,
                object: nil,
                userInfo: ["original": record.original, "corrected": record.corrected]
            )
        } catch {
            // Failed to add to dictionary
        }
    }
}

// MARK: - Additional Notification Names

extension Notification.Name {
    static let wordAddedToDictionary = Notification.Name("wordAddedToDictionary")
}
