//
//  CustomWordsView.swift
//  Hex
//
//  Custom word dictionary management view
//

import ComposableArchitecture
import SwiftUI

struct CustomWordsView: View {
    @Bindable var store: StoreOf<CustomWordsFeature>
    @State private var showingFilePicker = false

    var body: some View {
        Form {
            // Global toggle section
            Section {
                Toggle("Enable Custom Word Dictionary", isOn: Binding(
                    get: { store.customWordDictionary.isEnabled },
                    set: { _ in store.send(.toggleDictionaryEnabled) }
                ))
            } header: {
                Text("Custom Word Dictionary")
            } footer: {
                Text("Add prompt words to guide transcription, or replacement rules to fix output.")
                    .foregroundColor(.secondary.opacity(0.7))
                    .font(.caption)
            }

            if store.customWordDictionary.isEnabled {
                // Statistics
                statisticsSection

                // Add new entry section
                addEntrySection

                // Import/Export section
                importExportSection

                // Entries list
                if !store.customWordDictionary.entries.isEmpty {
                    entriesSection
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.send(.onAppear)
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.plainText, .json, .commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    store.send(.handleImportedFile(.success(url)))
                }
            case let .failure(error):
                store.send(.handleImportedFile(.failure(error)))
            }
        }
        .sheet(isPresented: Binding(
            get: { store.showNaturalInputSheet },
            set: { if !$0 { store.send(.dismissNaturalInputSheet) } }
        )) {
            naturalInputImportSheet
        }
        .alert("Import Successful", isPresented: Binding(
            get: { store.showImportSuccess },
            set: { if !$0 { store.send(.clearImportSuccess) } }
        )) {
            Button("OK") {
                store.send(.clearImportSuccess)
            }
        } message: {
            Text("Successfully imported \(store.importedCount) entries.")
        }
        .alert("Import Error", isPresented: Binding(
            get: { store.importError != nil },
            set: { if !$0 { store.send(.clearImportError) } }
        )) {
            Button("OK") {
                store.send(.clearImportError)
            }
        } message: {
            Text(store.importError ?? "Unknown error")
        }
    }

    // MARK: - Statistics Section

    private var statisticsSection: some View {
        Section {
            HStack {
                Label("Prompt Words", systemImage: "text.bubble")
                    .foregroundColor(.purple)
                Spacer()
                Text("\(store.enabledPromptEntries) / \(store.promptEntryCount)")
                    .foregroundColor(.secondary)
            }
            HStack {
                Label("Replacement Rules", systemImage: "arrow.left.arrow.right")
                    .foregroundColor(.blue)
                Spacer()
                Text("\(store.enabledReplacementEntries) / \(store.replacementEntryCount)")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Statistics")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt Words: Bias transcription to output these words")
                Text("Replacement Rules: Replace text after transcription")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Add Entry Section

    private var addEntrySection: some View {
        Section {
            // Entry type selector
            Picker("Type", selection: $store.newEntryType) {
                Text("Prompt Word").tag(CustomWordEntry.EntryType.prompt)
                Text("Replacement Rule").tag(CustomWordEntry.EntryType.replacement)
            }
            .pickerStyle(.segmented)

            // Input fields based on type
            if store.newEntryType == .prompt {
                // Prompt word: single word input
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Word to recognize")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g., 大肚", text: $store.newOriginal)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button(action: {
                        store.send(.addEntry)
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.purple)
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.newOriginal.isEmpty)
                }
                .padding(.vertical, 4)
            } else {
                // Replacement rule: original -> replacement
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Original")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g., 台灣", text: $store.newOriginal)
                            .textFieldStyle(.roundedBorder)
                    }

                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Replacement")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g., 臺灣", text: $store.newReplacement)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button(action: {
                        store.send(.addEntry)
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.newOriginal.isEmpty || store.newReplacement.isEmpty)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Add New Entry")
        } footer: {
            if store.newEntryType == .prompt {
                Text("Prompt words guide Whisper to recognize specific terms. Best for proper nouns, place names, and technical terms.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Replacement rules fix text after transcription. Use when Whisper consistently outputs wrong characters.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Import/Export Section

    private var importExportSection: some View {
        Section {
            // Import buttons
            HStack(spacing: 12) {
                Button(action: {
                    showingFilePicker = true
                }) {
                    Label("Import from File", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button(action: {
                    store.send(.loadNaturalInputEntries)
                }) {
                    Label("Import from Natural Input", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)
                .help("Import from Natural Input Method (自然輸入法)")
            }

            // Export buttons
            HStack(spacing: 12) {
                Button(action: {
                    store.send(.exportToCSV)
                }) {
                    Label("Export CSV", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)

                Button(action: {
                    store.send(.exportToJSON)
                }) {
                    Label("Export JSON", systemImage: "curlybraces")
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("Import / Export")
        } footer: {
            Text("CSV format: original,replacement (one per line). Exported data is copied to clipboard.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Entries Section

    private var entriesSection: some View {
        Section {
            // Type filter and search
            HStack(spacing: 12) {
                Picker("Filter", selection: $store.filterType) {
                    ForEach(CustomWordsFeature.State.EntryFilterType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                TextField("Search...", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
            }

            // Entries list
            ForEach(store.filteredEntries) { entry in
                EntryRow(entry: entry, store: store)
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let entry = store.filteredEntries[index]
                    store.send(.removeEntry(entry.id))
                }
            }
        } header: {
            Text("Entries (\(store.filteredEntries.count))")
        }
    }

    // MARK: - Natural Input Import Sheet

    private var naturalInputImportSheet: some View {
        VStack(spacing: 16) {
            Text("Import from Natural Input Method")
                .font(.headline)

            if store.isLoadingNaturalInput {
                ProgressView("Loading entries...")
            } else if store.naturalInputEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("No entries found")
                        .font(.headline)
                    Text("Make sure Natural Input Method is installed and has usage data.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Found \(store.naturalInputEntries.count) high-frequency words")
                        .font(.subheadline)

                    Text("This will analyze your Natural Input preferences and create replacement rules for commonly used Traditional Chinese characters.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(store.naturalInputEntries.prefix(20)) { entry in
                                HStack {
                                    Text(entry.pattern)
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Text("\(entry.hits) hits")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            if store.naturalInputEntries.count > 20 {
                                Text("... and \(store.naturalInputEntries.count - 20) more")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }

            HStack {
                Button("Cancel") {
                    store.send(.dismissNaturalInputSheet)
                }
                .buttonStyle(.bordered)

                if !store.naturalInputEntries.isEmpty {
                    Button("Import") {
                        store.send(.importSelectedNaturalInputEntries(store.naturalInputEntries))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .frame(width: 400, height: 400)
    }
}

// MARK: - Entry Row

struct EntryRow: View {
    let entry: CustomWordEntry
    let store: StoreOf<CustomWordsFeature>

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { _ in store.send(.toggleEntry(entry.id)) }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    // Entry type indicator
                    entryTypeLabel

                    if entry.isPromptEntry {
                        // Prompt entry: just show the word
                        Text(entry.original)
                            .fontWeight(.medium)
                            .strikethrough(!entry.isEnabled)
                            .foregroundColor(entry.isEnabled ? .primary : .secondary)
                    } else {
                        // Replacement entry: show original -> replacement
                        Text(entry.original)
                            .strikethrough(!entry.isEnabled)
                            .foregroundColor(entry.isEnabled ? .primary : .secondary)

                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(entry.replacement)
                            .fontWeight(.medium)
                            .foregroundColor(entry.isEnabled ? .primary : .secondary)
                    }
                }

                HStack(spacing: 8) {
                    sourceLabel(for: entry.source)

                    Text(entry.createdAt, style: .date)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: {
                store.send(.removeEntry(entry.id))
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var entryTypeLabel: some View {
        let (icon, color): (String, Color) = entry.isPromptEntry
            ? ("text.bubble", .purple)
            : ("arrow.left.arrow.right", .blue)

        return Image(systemName: icon)
            .font(.caption)
            .foregroundColor(color)
    }

    private func sourceLabel(for source: CustomWordEntry.EntrySource) -> some View {
        let (text, color): (String, Color) = switch source {
        case .manual: ("手動", .gray)
        case .imported: ("匯入", .green)
        case .naturalInput: ("自然輸入法", .orange)
        case .learned: ("自動學習", .blue)
        }

        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

#Preview {
    CustomWordsView(store: Store(initialState: CustomWordsFeature.State()) {
        CustomWordsFeature()
    })
    .frame(width: 600, height: 600)
}
