import ComposableArchitecture
import Dependencies
import IdentifiedCollections
import SwiftUI

public struct ModelInfo: Equatable, Identifiable {
	public let name: String
	public var isDownloaded: Bool

	public var id: String { name }

	public init(name: String, isDownloaded: Bool) {
		self.name = name
		self.isDownloaded = isDownloaded
	}
}

public struct CuratedModelInfo: Equatable, Identifiable, Codable {
	public let displayName: String
	public let internalName: String
	public let size: String
	public let accuracyStars: Int
	public let speedStars: Int
	public let storageSize: String
	public var isDownloaded: Bool
	
	public var id: String { internalName }
	
	public init(
		displayName: String,
		internalName: String,
		size: String,
		accuracyStars: Int,
		speedStars: Int,
		storageSize: String,
		isDownloaded: Bool
	) {
		self.displayName = displayName
		self.internalName = internalName
		self.size = size
		self.accuracyStars = accuracyStars
		self.speedStars = speedStars
		self.storageSize = storageSize
		self.isDownloaded = isDownloaded
	}
	
	// Codable init - doesn't include isDownloaded which gets set at runtime
	private enum CodingKeys: String, CodingKey {
		case displayName, internalName, size, accuracyStars, speedStars, storageSize
	}
	
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		displayName = try container.decode(String.self, forKey: .displayName)
		internalName = try container.decode(String.self, forKey: .internalName)
		size = try container.decode(String.self, forKey: .size)
		accuracyStars = try container.decode(Int.self, forKey: .accuracyStars)
		speedStars = try container.decode(Int.self, forKey: .speedStars)
		storageSize = try container.decode(String.self, forKey: .storageSize)
		isDownloaded = false // Default value, will be set at runtime
	}
}

@Reducer
public struct ModelDownloadFeature {
	@ObservableState
	public struct State {
		@Shared(.hexSettings) var hexSettings: HexSettings

		// List of all known models from getAvailableModels()
		public var availableModels: IdentifiedArrayOf<ModelInfo> = []
		
		// Curated list of models with user-friendly information
		public var curatedModels: IdentifiedArrayOf<CuratedModelInfo> = []

		// The recommended "default" from whisperKit
		public var recommendedModel: String = ""
		
		// Whether to show all models or just curated ones
		public var showAllModels: Bool = false

		// Current download / progress states
		public var isDownloading: Bool = false
		public var downloadProgress: Double = 0
		public var downloadError: String?
		public var downloadingModelName: String?

		public init() {}
	}

	public enum Action: BindableAction {
		case binding(BindingAction<State>)

		case fetchModels
		case fetchModelsResponse(String, [ModelInfo])

		case selectModel(String)
		case toggleModelDisplay
		
		case downloadSelectedModel
		case downloadProgress(Double)
		case downloadResponse(Result<String, Error>)

		case deleteSelectedModel
	}

	@Dependency(\.transcription) var transcription

	public init() {}

	public var body: some ReducerOf<Self> {
		BindingReducer()

		Reduce { state, action in
			switch action {
			case .binding:
				return .none

			// 1) Load the recommended model + the list of all available model names
			case .fetchModels:
				return .run { send in
					do {
						let recommended = try await transcription.getRecommendedModels().default
						let names = try await transcription.getAvailableModels()

						// Mark each model as downloaded or not
						var list = [ModelInfo]()
						for modelName in names {
							let downloaded = await transcription.isModelDownloaded(modelName)
							list.append(ModelInfo(name: modelName, isDownloaded: downloaded))
						}

						await send(.fetchModelsResponse(recommended, list))
					} catch {
						await send(.fetchModelsResponse("", []))
					}
				}

			case let .fetchModelsResponse(recommended, list):
				state.recommendedModel = recommended
				state.availableModels = IdentifiedArrayOf(uniqueElements: list)
				
				// Create our curated model list from models.json
				var curatedList: [CuratedModelInfo] = []
				
				// Load models from JSON file
				if let url = Bundle.main.url(forResource: "models", withExtension: "json", subdirectory: "Data"),
				   let data = try? Data(contentsOf: url),
				   let modelDefinitions = try? JSONDecoder().decode([CuratedModelInfo].self, from: data) {
					
					// Update download status for each model
					for var modelDefinition in modelDefinitions {
						// Find download status in the fetched model list
						let isDownloaded = list.first(where: { $0.name == modelDefinition.internalName })?.isDownloaded ?? false
						modelDefinition.isDownloaded = isDownloaded
						curatedList.append(modelDefinition)
					}
				} else {
					// Fallback to default models if JSON loading fails
					let smallModelName = "openai_whisper-tiny-v3-v20240930"
					let mediumModelName = "openai_whisper-medium-v3-v20240930"
					let largeModelName = "openai_whisper-large-v3-v20240930"
					
					let isSmallDownloaded = list.first(where: { $0.name == smallModelName })?.isDownloaded ?? false
					let isMediumDownloaded = list.first(where: { $0.name == mediumModelName })?.isDownloaded ?? false
					let isLargeDownloaded = list.first(where: { $0.name == largeModelName })?.isDownloaded ?? false
					
					// Create our curated model infos as fallback
					curatedList.append(
						CuratedModelInfo(
							displayName: "Small",
							internalName: smallModelName,
							size: "Small",
							accuracyStars: 2,
							speedStars: 4,
							storageSize: "100MB",
							isDownloaded: isSmallDownloaded
						)
					)
					
					curatedList.append(
						CuratedModelInfo(
							displayName: "Medium",
							internalName: mediumModelName,
							size: "Medium",
							accuracyStars: 3,
							speedStars: 3,
							storageSize: "500MB",
							isDownloaded: isMediumDownloaded
						)
					)
					
					curatedList.append(
						CuratedModelInfo(
							displayName: "Large",
							internalName: largeModelName,
							size: "Large",
							accuracyStars: 4,
							speedStars: 2,
							storageSize: "1GB",
							isDownloaded: isLargeDownloaded
						)
					)
				}
				
				state.curatedModels = IdentifiedArrayOf(uniqueElements: curatedList)
				return .none

			// 2) The user picks a new model => update & check if downloaded
			case let .selectModel(newModel):
				state.$hexSettings.withLock { $0.selectedModel = newModel }
				return .none
				
			case .toggleModelDisplay:
				state.showAllModels.toggle()
				return .none

			// 3) Download the currently selected model
			case .downloadSelectedModel:
				let model = state.hexSettings.selectedModel
				guard !model.isEmpty else { return .none }

				state.isDownloading = true
				state.downloadProgress = 0
				state.downloadError = nil
				state.downloadingModelName = model

				return .run { send in
					do {
						// Start the download & track progress
						try await transcription.downloadModel(model) { prog in
							Task { await send(.downloadProgress(prog.fractionCompleted)) }
						}
						await send(.downloadResponse(.success(model)))
					} catch {
						await send(.downloadResponse(.failure(error)))
					}
				}

			// 4) Delete the currently selected model
			case .deleteSelectedModel:
				let model = state.hexSettings.selectedModel
				guard !model.isEmpty else { return .none }
				
				return .run { send in
					do {
						try await transcription.deleteModel(model)
						
						// Simply reload all models to refresh status
						await send(.fetchModels)
					} catch {
						await send(.downloadResponse(.failure(error)))
					}
				}

			case let .downloadProgress(value):
				state.downloadProgress = value
				return .none

			case let .downloadResponse(.success(modelName)):
				state.isDownloading = false
				state.downloadProgress = 1
				state.downloadError = nil
				state.downloadingModelName = nil

				// Mark it as downloaded in the list
				state.availableModels[id: modelName]?.isDownloaded = true
				
				// Also update the curated model list if it's one of our curated models
				if let curatedIndex = state.curatedModels.firstIndex(where: { $0.internalName == modelName }) {
					state.curatedModels[curatedIndex].isDownloaded = true
				}
				
				return .none

			case let .downloadResponse(.failure(err)):
				state.isDownloading = false
				state.downloadError = err.localizedDescription
				state.downloadProgress = 0
				state.downloadingModelName = nil
				return .none
			}
		}
	}
}

struct StarRatingView: View {
	let filledStars: Int
	let maxStars: Int
	
	init(rating: Int, maxRating: Int = 5) {
		self.filledStars = rating
		self.maxStars = maxRating
	}
	
	var body: some View {
		HStack(spacing: 3) {
			ForEach(0..<maxStars, id: \.self) { dot in
				Image(systemName: dot < filledStars ? "circle.fill" : "circle")
					.foregroundColor(dot < filledStars ? .blue : .gray.opacity(0.5))
					.font(.system(size: 7))
			}
		}
	}
}

struct ModelDownloadView: View {
	@Bindable var store: StoreOf<ModelDownloadFeature>

	var body: some View {
		if store.availableModels.isEmpty {
			Text("No models found.").foregroundColor(.secondary)
		} else {
			VStack(alignment: .leading, spacing: 12) {
				// Toggle between curated and all models
				HStack {
					Text(store.showAllModels ? "Showing all models" : "Showing recommended models")
						.font(.caption)
						.foregroundColor(.secondary)
					
					Spacer()
					
					Button(store.showAllModels ? "Show Recommended" : "Show All Models") {
						store.send(.toggleModelDisplay)
					}
					.font(.caption)
				}
				
				if store.showAllModels {
					// Show all models in a picker
					Picker("Selected Model", selection: Binding(
						get: { store.hexSettings.selectedModel },
						set: { store.send(.selectModel($0)) }
					)) {
						ForEach(store.availableModels) { info in
							let isRecommended = info.name == store.recommendedModel
							let name = isRecommended ? "\(info.name) (Recommended)" : info.name
							HStack {
								Text(name)
								if info.isDownloaded {
									Spacer()
									Image(systemName: "checkmark.circle.fill")
										.foregroundColor(.green)
								}
							}
							.tag(info.name)
						}
					}
					.pickerStyle(.menu)
				} else {
					// Show curated model list with detailed info
					VStack(alignment: .leading, spacing: 16) {
						// Table header
						HStack(alignment: .bottom) {
							Text("Model")
								.font(.caption.bold())
								.frame(width: 80, alignment: .leading)
							
							VStack(alignment: .leading, spacing: 2) {
								Text("Accuracy")
									.font(.caption.bold())
								StarRatingView(rating: 0)
							}
							.frame(width: 80, alignment: .leading)
							
							VStack(alignment: .leading, spacing: 2) {
								Text("Speed")
									.font(.caption.bold())
								StarRatingView(rating: 0)
							}
							.frame(width: 80, alignment: .leading)
							
							Text("Size")
								.font(.caption.bold())
								.frame(width: 80, alignment: .leading)
						}
						.padding(.horizontal, 8)
						
						// Model rows
						ForEach(store.curatedModels) { model in
							Button {
								store.send(.selectModel(model.internalName))
							} label: {
								HStack(alignment: .center) {
									// Model name
									HStack {
										Text(model.displayName)
											.font(.headline)
										
										if model.isDownloaded {
											Image(systemName: "checkmark.circle.fill")
												.foregroundColor(.green)
												.font(.caption)
										}
										
										if model.internalName == store.hexSettings.selectedModel {
											Image(systemName: "checkmark")
												.foregroundColor(.blue)
												.font(.caption)
										}
									}
									.frame(width: 80, alignment: .leading)
									
									// Accuracy rating
									VStack(alignment: .leading) {
										StarRatingView(rating: model.accuracyStars)
									}
									.frame(width: 80, alignment: .leading)
									
									// Speed rating
									VStack(alignment: .leading) {
										StarRatingView(rating: model.speedStars)
									}
									.frame(width: 80, alignment: .leading)
									
									// Storage size
									Text(model.storageSize)
										.font(.body)
										.foregroundColor(.secondary)
										.frame(width: 80, alignment: .leading)
								}
								.padding(8)
								.background(
									RoundedRectangle(cornerRadius: 8)
										.fill(model.internalName == store.hexSettings.selectedModel ? 
											  Color.blue.opacity(0.1) : Color.clear)
								)
								.overlay(
									RoundedRectangle(cornerRadius: 8)
										.stroke(model.internalName == store.hexSettings.selectedModel ? 
												Color.blue.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
								)
							}
							.buttonStyle(.plain)
						}
					}
				}
				
				if let error = store.downloadError {
					Text("Download Error: \(error)")
						.foregroundColor(.red)
						.font(.caption)
				}
				
				// Download progress or download/delete buttons
				if store.isDownloading,
				   let downloadingName = store.downloadingModelName,
				   downloadingName == store.hexSettings.selectedModel
				{
					VStack(alignment: .leading) {
						Text("Downloading model...")
							.font(.caption)
						ProgressView(value: store.downloadProgress, total: 1.0)
							.tint(.blue)
							.padding(.vertical, 4)
					}
				} else {
					HStack {
						// Selected model display
						if let selectedModel = store.curatedModels.first(where: { $0.internalName == store.hexSettings.selectedModel }) {
							Text("Selected: \(selectedModel.displayName)")
								.font(.caption)
						} else if let selectedName = store.availableModels.first(where: { $0.name == store.hexSettings.selectedModel })?.name {
							Text("Selected: \(selectedName)")
								.font(.caption)
						}
						
						Spacer()
						
						// Show Delete button if model is downloaded
						if let selectedInfo = store.availableModels
							.first(where: { $0.name == store.hexSettings.selectedModel }),
							selectedInfo.isDownloaded
						{
							Button(role: .destructive, action: {
								store.send(.deleteSelectedModel)
							}) {
								Text("Delete")
									.font(.caption)
							}
							.buttonStyle(.borderless)
							.padding(.trailing, 8)
						}
						
						// Show Download button if not downloaded yet
						if let selectedInfo = store.availableModels
							.first(where: { $0.name == store.hexSettings.selectedModel }),
							!selectedInfo.isDownloaded
						{
							Button {
								store.send(.downloadSelectedModel)
							} label: {
								Text("Download")
									.font(.caption)
							}
							.buttonStyle(.borderless)
						}
					}
				}
			}
			.task {
				if store.availableModels.isEmpty {
					store.send(.fetchModels)
				}
			}
		}
	}
}