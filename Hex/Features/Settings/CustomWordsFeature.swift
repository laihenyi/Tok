//
//  CustomWordsFeature.swift
//  Hex
//
//  Custom word dictionary feature for improving transcription accuracy
//

import ComposableArchitecture
import Foundation
import SwiftUI

// MARK: - Custom Words Feature

@Reducer
struct CustomWordsFeature {
    @ObservableState
    struct State {
        @Shared(.customWordDictionary) var customWordDictionary: CustomWordDictionary

        // UI State
        var newOriginal: String = ""
        var newReplacement: String = ""
        var newEntryType: CustomWordEntry.EntryType = .prompt  // Default to prompt type
        var searchText: String = ""
        var filterType: EntryFilterType = .all  // Filter entries by type
        var isImporting: Bool = false
        var importError: String? = nil
        var showImportSuccess: Bool = false
        var importedCount: Int = 0

        enum EntryFilterType: String, CaseIterable {
            case all = "All"
            case prompt = "Prompt"
            case replacement = "Replacement"
        }

        // Natural Input Method import state
        var naturalInputEntries: [NaturalInputEntry] = []
        var isLoadingNaturalInput: Bool = false
        var showNaturalInputSheet: Bool = false

        // Computed: filtered entries based on search and type filter
        var filteredEntries: [CustomWordEntry] {
            var entries = customWordDictionary.entries

            // Apply type filter
            switch filterType {
            case .all:
                break
            case .prompt:
                entries = entries.filter { $0.isPromptEntry }
            case .replacement:
                entries = entries.filter { $0.isReplacementEntry }
            }

            // Apply search filter
            guard !searchText.isEmpty else {
                return entries
            }
            let lowercased = searchText.lowercased()
            return entries.filter { entry in
                entry.original.lowercased().contains(lowercased) ||
                    entry.replacement.lowercased().contains(lowercased)
            }
        }

        // Statistics
        var totalEntries: Int {
            customWordDictionary.entries.count
        }

        var enabledEntries: Int {
            customWordDictionary.entries.filter { $0.isEnabled }.count
        }

        var promptEntryCount: Int {
            customWordDictionary.entries.filter { $0.isPromptEntry }.count
        }

        var replacementEntryCount: Int {
            customWordDictionary.entries.filter { $0.isReplacementEntry }.count
        }

        var enabledPromptEntries: Int {
            customWordDictionary.enabledPromptEntries.count
        }

        var enabledReplacementEntries: Int {
            customWordDictionary.enabledReplacementEntries.count
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)

        // Lifecycle
        case onAppear
        case reloadDictionary

        // Entry management
        case addEntry
        case removeEntry(UUID)
        case toggleEntry(UUID)
        case updateEntry(CustomWordEntry)

        // Global toggle
        case toggleDictionaryEnabled

        // Import/Export
        case importFromCSV(String)
        case importFromJSON(String)
        case importCompleted(Result<Int, Error>)
        case exportToCSV
        case exportToJSON
        case clearImportError
        case clearImportSuccess

        // Natural Input Method import
        case loadNaturalInputEntries
        case naturalInputEntriesLoaded(Result<[NaturalInputEntry], Error>)
        case importSelectedNaturalInputEntries([NaturalInputEntry])
        case dismissNaturalInputSheet

        // File picker
        case showImportFilePicker
        case handleImportedFile(Result<URL, Error>)
    }

    var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .onAppear:
                // Reload dictionary from disk when view appears
                return .send(.reloadDictionary)

            case .reloadDictionary:
                // Force reload from disk
                let url = URL.documentsDirectory.appending(component: "hex_custom_words.json")
                print("[CustomWordsFeature] Reloading dictionary from: \(url.path)")

                if FileManager.default.fileExists(atPath: url.path) {
                    do {
                        let data = try Data(contentsOf: url)
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        let loadedDictionary = try decoder.decode(CustomWordDictionary.self, from: data)
                        print("[CustomWordsFeature] Loaded \(loadedDictionary.entries.count) entries")

                        state.$customWordDictionary.withLock { dict in
                            dict = loadedDictionary
                        }
                    } catch {
                        print("[CustomWordsFeature] Error loading dictionary: \(error)")
                    }
                } else {
                    print("[CustomWordsFeature] Dictionary file does not exist")
                }
                return .none

            case .addEntry:
                let original = state.newOriginal.trimmingCharacters(in: .whitespaces)
                let replacement = state.newReplacement.trimmingCharacters(in: .whitespaces)

                // For prompt type, only original is required; replacement can be same as original
                let isPromptType = state.newEntryType == .prompt
                guard !original.isEmpty else { return .none }
                guard isPromptType || !replacement.isEmpty else { return .none }

                let entry = CustomWordEntry(
                    original: original,
                    replacement: isPromptType ? original : replacement,
                    source: .manual,
                    entryType: state.newEntryType
                )

                state.$customWordDictionary.withLock { dict in
                    dict.addEntry(entry)
                }

                // Clear input fields
                state.newOriginal = ""
                state.newReplacement = ""

                // Invalidate cache
                invalidateCustomWordDictionaryCache()

                return .none

            case let .removeEntry(id):
                state.$customWordDictionary.withLock { dict in
                    dict.removeEntry(id: id)
                }
                invalidateCustomWordDictionaryCache()
                return .none

            case let .toggleEntry(id):
                if let index = state.customWordDictionary.entries.firstIndex(where: { $0.id == id }) {
                    state.$customWordDictionary.withLock { dict in
                        dict.entries[index].isEnabled.toggle()
                        dict.lastModified = Date()
                    }
                    invalidateCustomWordDictionaryCache()
                }
                return .none

            case let .updateEntry(entry):
                state.$customWordDictionary.withLock { dict in
                    dict.updateEntry(entry)
                }
                invalidateCustomWordDictionaryCache()
                return .none

            case .toggleDictionaryEnabled:
                state.$customWordDictionary.withLock { dict in
                    dict.isEnabled.toggle()
                    dict.lastModified = Date()
                }
                invalidateCustomWordDictionaryCache()
                return .none

            case let .importFromCSV(csvString):
                state.isImporting = true
                state.importError = nil

                return .run { send in
                    do {
                        let entries = try CustomWordDictionary.importFromCSV(csvString)

                        // Add entries to dictionary on main actor
                        await MainActor.run {
                            @Shared(.customWordDictionary) var dict
                            $dict.withLock { d in
                                d.addEntries(entries)
                            }
                            invalidateCustomWordDictionaryCache()
                        }

                        await send(.importCompleted(.success(entries.count)))
                    } catch {
                        await send(.importCompleted(.failure(error)))
                    }
                }

            case let .importFromJSON(jsonString):
                state.isImporting = true
                state.importError = nil

                return .run { send in
                    do {
                        let imported = try CustomWordDictionary.importFromJSON(jsonString)
                        let entryCount = imported.entries.count

                        // Replace dictionary on main actor
                        await MainActor.run {
                            @Shared(.customWordDictionary) var dict
                            $dict.withLock { d in
                                d = imported
                            }
                            invalidateCustomWordDictionaryCache()
                        }

                        await send(.importCompleted(.success(entryCount)))
                    } catch {
                        await send(.importCompleted(.failure(error)))
                    }
                }

            case let .importCompleted(result):
                state.isImporting = false
                switch result {
                case let .success(count):
                    state.importedCount = count
                    state.showImportSuccess = true
                case let .failure(error):
                    state.importError = error.localizedDescription
                }
                return .none

            case .exportToCSV:
                let csv = state.customWordDictionary.exportToCSV()
                // Copy to clipboard
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(csv, forType: .string)
                return .none

            case .exportToJSON:
                do {
                    let json = try state.customWordDictionary.exportToJSON()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                } catch {
                    state.importError = "Export failed: \(error.localizedDescription)"
                }
                return .none

            case .clearImportError:
                state.importError = nil
                return .none

            case .clearImportSuccess:
                state.showImportSuccess = false
                state.importedCount = 0
                return .none

            case .loadNaturalInputEntries:
                state.isLoadingNaturalInput = true
                state.showNaturalInputSheet = true

                return .run { send in
                    do {
                        let entries = try CustomWordDictionary.importFromNaturalInputMethod(
                            minimumHits: 50,
                            maxEntries: 1000
                        )
                        await send(.naturalInputEntriesLoaded(.success(entries)))
                    } catch {
                        await send(.naturalInputEntriesLoaded(.failure(error)))
                    }
                }

            case let .naturalInputEntriesLoaded(result):
                state.isLoadingNaturalInput = false
                switch result {
                case let .success(entries):
                    state.naturalInputEntries = entries
                case let .failure(error):
                    state.importError = "Failed to load Natural Input entries: \(error.localizedDescription)"
                    state.showNaturalInputSheet = false
                }
                return .none

            case let .importSelectedNaturalInputEntries(entries):
                // For now, we'll use a simple heuristic:
                // If the pattern uses 臺 instead of 台, add a replacement rule
                var newEntries: [CustomWordEntry] = []

                for entry in entries {
                    // Check for Traditional Chinese character preferences
                    // 臺灣 vs 台灣, 著 vs 着, etc.
                    let traditionalChars = ["臺", "著", "裡", "麵", "隻"]
                    let simplifiedChars = ["台", "着", "里", "面", "只"]

                    for (traditional, simplified) in zip(traditionalChars, simplifiedChars) {
                        if entry.pattern.contains(traditional) {
                            // Create a replacement rule for this specific word
                            let simplifiedVersion = entry.pattern.replacingOccurrences(of: traditional, with: simplified)
                            if simplifiedVersion != entry.pattern {
                                newEntries.append(CustomWordEntry(
                                    original: simplifiedVersion,
                                    replacement: entry.pattern,
                                    source: .naturalInput
                                ))
                            }
                        }
                    }
                }

                // Also add any custom words (isCustom = 1) directly
                // These are user-defined words that should be preserved

                state.$customWordDictionary.withLock { dict in
                    dict.addEntries(newEntries)
                }
                state.showNaturalInputSheet = false
                state.naturalInputEntries = []
                state.importedCount = newEntries.count
                state.showImportSuccess = true
                invalidateCustomWordDictionaryCache()
                return .none

            case .dismissNaturalInputSheet:
                state.showNaturalInputSheet = false
                state.naturalInputEntries = []
                return .none

            case .showImportFilePicker:
                // This will be handled by the view
                return .none

            case let .handleImportedFile(result):
                switch result {
                case let .success(url):
                    return .run { send in
                        do {
                            let content = try String(contentsOf: url, encoding: .utf8)
                            let fileExtension = url.pathExtension.lowercased()

                            if fileExtension == "json" {
                                await send(.importFromJSON(content))
                            } else {
                                // Treat as CSV
                                await send(.importFromCSV(content))
                            }
                        } catch {
                            await send(.importCompleted(.failure(error)))
                        }
                    }
                case let .failure(error):
                    state.importError = error.localizedDescription
                    return .none
                }
            }
        }
    }
}
