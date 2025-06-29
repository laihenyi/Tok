import AVFoundation
import ComposableArchitecture
import Dependencies
import SwiftUI
import WhisperKit

// MARK: - Models

struct Transcript: Codable, Equatable, Identifiable {
	var id: UUID
	var timestamp: Date
	/// The original, unedited transcription returned directly from Whisper.
	/// This is always stored so the user can reference the raw text even after
	/// optional AI enhancement is applied.
	var rawText: String?
	/// The (optionally) enhanced transcription shown by default in the UI.
	/// For backward-compatibility this continues to use the original `text` key
	/// so older JSON files remain readable without migration.
	var text: String
	var audioPath: URL
	var duration: TimeInterval
	
	// MARK: - Codable
	// We maintain manual CodingKeys so that existing `text` field from older
	// versions decodes into the `text` property while gracefully ignoring the
	// new `rawText` key if missing.
	private enum CodingKeys: String, CodingKey {
		case id, timestamp, text, rawText, audioPath, duration
	}

	init(id: UUID = UUID(), timestamp: Date, text: String, rawText: String? = nil, audioPath: URL, duration: TimeInterval) {
		self.id = id
		self.timestamp = timestamp
		self.text = text
		self.rawText = rawText
		self.audioPath = audioPath
		self.duration = duration
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
		timestamp = try container.decode(Date.self, forKey: .timestamp)
		// For legacy records that only have `text`, we treat it as both raw and enhanced.
		let decodedText = try container.decode(String.self, forKey: .text)
		text = decodedText
		rawText = try container.decodeIfPresent(String.self, forKey: .rawText) ?? decodedText
		audioPath = try container.decode(URL.self, forKey: .audioPath)
		duration = try container.decode(TimeInterval.self, forKey: .duration)
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(timestamp, forKey: .timestamp)
		try container.encode(text, forKey: .text)
		// Only encode rawText separately if it differs from `text` to avoid
		// bloating the JSON.
		if let rawText, rawText != text {
			try container.encode(rawText, forKey: .rawText)
		}
		try container.encode(audioPath, forKey: .audioPath)
		try container.encode(duration, forKey: .duration)
	}
}

struct TranscriptionHistory: Codable, Equatable {
	var history: [Transcript] = []
}

extension SharedReaderKey
	where Self == FileStorageKey<TranscriptionHistory>.Default
{
	static var transcriptionHistory: Self {
		Self[
			.fileStorage(URL.documentsDirectory.appending(component: "transcription_history.json")),
			default: .init()
		]
	}
}

class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
	private var player: AVAudioPlayer?
	var onPlaybackFinished: (() -> Void)?

	func play(url: URL) throws -> AVAudioPlayer {
		let player = try AVAudioPlayer(contentsOf: url)
		player.delegate = self
		player.play()
		self.player = player
		return player
	}

	func stop() {
		player?.stop()
		player = nil
	}

	// AVAudioPlayerDelegate method
	func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		self.player = nil
		Task { @MainActor in
			onPlaybackFinished?()
		}
	}
}

// MARK: - History Feature

@Reducer
struct HistoryFeature {
	@ObservableState
	struct State: Equatable {
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		var playingTranscriptID: UUID?
		var audioPlayer: AVAudioPlayer?
		var audioPlayerController: AudioPlayerController?
		@Shared(.hexSettings) var hexSettings: HexSettings
	}

	enum Action {
		case playTranscript(UUID)
		case stopPlayback
		case copyToClipboard(String)
		case deleteTranscript(UUID)
		case deleteAllTranscripts
		case confirmDeleteAll
		case playbackFinished
		case retranscribeTranscript(UUID)
		case openRecordingsFolder
	}

	@Dependency(\.pasteboard) var pasteboard
	@Dependency(\.transcription) var transcription
	@Dependency(\.soundEffects) var soundEffect

	var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case let .playTranscript(id):
				if state.playingTranscriptID == id {
					// Stop playback if tapping the same transcript
					state.audioPlayerController?.stop()
					state.audioPlayer = nil
					state.audioPlayerController = nil
					state.playingTranscriptID = nil
					return .none
				}

				// Stop any existing playback
				state.audioPlayerController?.stop()
				state.audioPlayer = nil
				state.audioPlayerController = nil

				// Find the transcript and play its audio
				guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
					return .none
				}

				do {
					let controller = AudioPlayerController()
					let player = try controller.play(url: transcript.audioPath)

					state.audioPlayer = player
					state.audioPlayerController = controller
					state.playingTranscriptID = id

					return .run { send in
						// Using non-throwing continuation since we don't need to throw errors
						await withCheckedContinuation { continuation in
							controller.onPlaybackFinished = {
								continuation.resume()

								// Use Task to switch to MainActor for sending the action
								Task { @MainActor in
									send(.playbackFinished)
								}
							}
						}
					}
				} catch {
					print("Error playing audio: \(error)")
					return .none
				}

			case .stopPlayback, .playbackFinished:
				state.audioPlayerController?.stop()
				state.audioPlayer = nil
				state.audioPlayerController = nil
				state.playingTranscriptID = nil
				return .none

			case let .copyToClipboard(text):
				return .run { _ in
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(text, forType: .string)
				}

			case let .deleteTranscript(id):
				guard let index = state.transcriptionHistory.history.firstIndex(where: { $0.id == id }) else {
					return .none
				}

				let transcript = state.transcriptionHistory.history[index]

				if state.playingTranscriptID == id {
					state.audioPlayerController?.stop()
					state.audioPlayer = nil
					state.audioPlayerController = nil
					state.playingTranscriptID = nil
				}

				_ = state.$transcriptionHistory.withLock { history in
					history.history.remove(at: index)
				}

				return .run { _ in
					try? FileManager.default.removeItem(at: transcript.audioPath)
				}

			case .deleteAllTranscripts:
				return .send(.confirmDeleteAll)

			case .confirmDeleteAll:
				let transcripts = state.transcriptionHistory.history

				state.audioPlayerController?.stop()
				state.audioPlayer = nil
				state.audioPlayerController = nil
				state.playingTranscriptID = nil

				state.$transcriptionHistory.withLock { history in
					history.history.removeAll()
				}

				return .run { _ in
					for transcript in transcripts {
						try? FileManager.default.removeItem(at: transcript.audioPath)
					}
				}

			case let .retranscribeTranscript(id):
				// Stop any playback when retranscribing
				state.audioPlayerController?.stop()
				state.audioPlayer = nil
				state.audioPlayerController = nil
				state.playingTranscriptID = nil

				guard let original = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
					return .none
				}

				let model = state.hexSettings.selectedModel
				let language = state.hexSettings.outputLanguage
				let settings = state.hexSettings
				let transcriptionHistory = state.$transcriptionHistory

				return .run { _ in
					do {
						let options = DecodingOptions(
							language: language,
							detectLanguage: language == nil,
							chunkingStrategy: .vad
						)
						// Perform transcription
						let result = try await transcription.transcribe(original.audioPath, model, options, settings, nil) { _ in }

						// Skip if result empty
						guard !result.isEmpty else { return }

						// Create new transcript referencing same audio file
						let newTranscript = Transcript(
							timestamp: Date(),
							text: result,
							audioPath: original.audioPath,
							duration: original.duration
						)

						transcriptionHistory.withLock { history in
							history.history.insert(newTranscript, at: 0)
						}

						// Paste and play sound
						await pasteboard.paste(result)
						await soundEffect.play(.pasteTranscript)
					} catch {
						print("Error re-transcribing audio: \(error)")
					}
				}

			case .openRecordingsFolder:
				return .run { _ in
					do {
						let fm = FileManager.default
						let supportDir = try fm.url(
							for: .applicationSupportDirectory,
							in: .userDomainMask,
							appropriateFor: nil,
							create: true
						)
						let ourAppFolder = supportDir.appendingPathComponent("xyz.2qs.Tok", isDirectory: true)
						let recordingsFolder = ourAppFolder.appendingPathComponent("Recordings", isDirectory: true)

						// Create the folder if it doesn't exist
						try fm.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)

						// Open the folder in Finder
						NSWorkspace.shared.open(recordingsFolder)
					} catch {
						print("Error opening recordings folder: \(error)")
					}
				}
			}
		}
	}
}

struct TranscriptView: View {
	let transcript: Transcript
	let isPlaying: Bool
	let onPlay: () -> Void
	let onCopy: () -> Void
	let onDelete: () -> Void
	let onRetranscribe: () -> Void

	@State private var showCopied = false
	@State private var copyTask: Task<Void, Error>?
	@State private var showRaw: Bool = false

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Enhanced (or final) transcription shown by default.
			Text(transcript.text)
				.font(.body)
				.lineLimit(nil)
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.trailing, 40) // Space for buttons
				.padding(.horizontal, 12)
				.padding(.vertical, 12)

			// Collapsible raw transcription, if available and distinct.
			if let raw = transcript.rawText, raw != transcript.text {
				DisclosureGroup(isExpanded: $showRaw) {
					Text(raw)
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.leading)
						.frame(maxWidth: .infinity, alignment: .leading)
						.lineLimit(nil)
						.textSelection(.enabled)
						.fixedSize(horizontal: false, vertical: true)
						.padding(.top, 4)
				} label: {
					Text("Raw transcription")
						.font(.caption)
						.foregroundStyle(.secondary)
						.contentShape(Rectangle())
						.onTapGesture {
							showRaw.toggle()
						}
				}
				.padding(.horizontal, 12)
				.padding(.bottom, 8)
			}

			Divider()

			HStack {
				HStack(spacing: 6) {
					Image(systemName: "clock")
					Text(transcript.timestamp.formatted(date: .numeric, time: .shortened))
					Text("•")
					Text(String(format: "%.1fs", transcript.duration))
				}
				.font(.subheadline)
				.foregroundStyle(.secondary)

				Spacer()

				HStack(spacing: 10) {
					Button {
						onCopy()
						showCopyAnimation()
					} label: {
						HStack(spacing: 4) {
							Image(systemName: showCopied ? "checkmark" : "doc.on.doc.fill")
							if showCopied {
								Text("Copied").font(.caption)
							}
						}
					}
					.buttonStyle(.plain)
					.foregroundStyle(showCopied ? .green : .secondary)
					.help("Copy to clipboard")

					Button(action: onPlay) {
						Image(systemName: isPlaying ? "stop.fill" : "play.fill")
					}
					.buttonStyle(.plain)
					.foregroundStyle(isPlaying ? .blue : .secondary)
					.help(isPlaying ? "Stop playback" : "Play audio")

					Button(action: onRetranscribe) {
						Image(systemName: "arrow.clockwise")
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
					.help("Re-run transcription")

					Button(action: onDelete) {
						Image(systemName: "trash.fill")
					}
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
					.help("Delete transcript")
				}
				.font(.subheadline)
			}
			.frame(height: 20)
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
		}
		.background(
			RoundedRectangle(cornerRadius: 8)
				.fill(Color(.windowBackgroundColor).opacity(0.5))
				.overlay(
					RoundedRectangle(cornerRadius: 8)
						.strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
				)
		)
		.onDisappear {
			// Clean up any running task when view disappears
			copyTask?.cancel()
		}
	}

	private func showCopyAnimation() {
		copyTask?.cancel()

		copyTask = Task {
			withAnimation {
				showCopied = true
			}

			try await Task.sleep(for: .seconds(1.5))

			withAnimation {
				showCopied = false
			}
		}
	}
}

#Preview {
	TranscriptView(
		transcript: Transcript(timestamp: Date(), text: "Hello, world!", audioPath: URL(fileURLWithPath: "/Users/langton/Downloads/test.m4a"), duration: 1.0),
		isPlaying: false,
		onPlay: {},
		onCopy: {},
		onDelete: {},
		onRetranscribe: {}
	)
}

struct HistoryView: View {
	let store: StoreOf<HistoryFeature>
	@State private var showingDeleteConfirmation = false

	var body: some View {
		if store.transcriptionHistory.history.isEmpty {
			ContentUnavailableView {
				Label("No Transcriptions", systemImage: "text.bubble")
			} description: {
				Text("Your transcription history will appear here.")
			}
		} else {
			ScrollView {
				LazyVStack(spacing: 12) {
					ForEach(store.transcriptionHistory.history) { transcript in
						TranscriptView(
							transcript: transcript,
							isPlaying: store.playingTranscriptID == transcript.id,
							onPlay: { store.send(.playTranscript(transcript.id)) },
							onCopy: { store.send(.copyToClipboard(transcript.text)) },
							onDelete: { store.send(.deleteTranscript(transcript.id)) },
							onRetranscribe: { store.send(.retranscribeTranscript(transcript.id)) }
						)
					}
				}
				.padding()
			}
			.toolbar {
				ToolbarItemGroup(placement: .primaryAction) {
					Button(action: { store.send(.openRecordingsFolder) }) {
						Label("Open Recordings Folder", systemImage: "folder")
					}
					.help("Open recordings folder in Finder")

					Button(role: .destructive, action: { showingDeleteConfirmation = true }) {
						Label("Delete All", systemImage: "trash")
					}
				}
			}
			.alert("Delete All Transcripts", isPresented: $showingDeleteConfirmation) {
				Button("Delete All", role: .destructive) {
					store.send(.confirmDeleteAll)
				}
				Button("Cancel", role: .cancel) {}
			} message: {
				Text("Are you sure you want to delete all transcripts? This action cannot be undone.")
			}
		}
	}
}
