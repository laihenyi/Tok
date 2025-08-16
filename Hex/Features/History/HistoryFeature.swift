import AVFoundation
import ComposableArchitecture
import Dependencies
import SwiftUI
import WhisperKit

// MARK: - Models

struct Transcript: Codable, Equatable, Identifiable {
	var id: UUID
	var timestamp: Date
	var text: String
	var audioPath: URL
	var duration: TimeInterval
	
	init(id: UUID = UUID(), timestamp: Date, text: String, audioPath: URL, duration: TimeInterval) {
		self.id = id
		self.timestamp = timestamp
		self.text = text
		self.audioPath = audioPath
		self.duration = duration
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
						// Normalize Chinese language codes for WhisperKit
						let normalizedLanguage = HistoryFeature.normalizeLanguageForWhisper(language)
						let options = DecodingOptions(
							language: normalizedLanguage,
							detectLanguage: normalizedLanguage == nil,
							chunkingStrategy: .vad
						)
						// Perform transcription
						let result = try await transcription.transcribe(original.audioPath, model, options, settings) { _ in }

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

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(transcript.text)
				.font(.body)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.trailing, 40) // Space for buttons
				.padding(12)

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

	@State private var showCopied = false
	@State private var copyTask: Task<Void, Error>?

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
				Button(role: .destructive, action: { showingDeleteConfirmation = true }) {
					Label("Delete All", systemImage: "trash")
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

// MARK: - Language Utilities
private extension HistoryFeature {
	/// Normalizes language codes for WhisperKit compatibility
	/// Converts zh-cn/zh-tw to zh for WhisperKit processing
	static func normalizeLanguageForWhisper(_ language: String?) -> String? {
		guard let language = language else { return nil }
		
		// WhisperKit uses "zh" for all Chinese variants
		if language.hasPrefix("zh") {
			return "zh"
		}
		
		return language
	}
}
