import ComposableArchitecture
import Foundation
import Sauce

// Shared flag used when the user is currently editing the Karaoke hotkey in the live settings panel.
extension SharedReaderKey where Self == InMemoryKey<Bool>.Default {
    static var isSettingKaraokeHotKey: Self {
        Self[.inMemory("isSettingKaraokeHotKey"), default: false]
    }
}

@Reducer
struct LiveSettingsFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.hexSettings) var hexSettings: HexSettings
        @Shared(.isSettingKaraokeHotKey) var isSettingKaraokeHotKey: Bool = false
        /// While capturing a new karaoke hotkey we accumulate pressed modifiers here until a key or release finalises it.
        var currentKaraokeModifiers: Modifiers = .init(modifiers: [])
        var availableOutputDevices: [AudioOutputDevice] = []
    }
    
    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case loadAvailableOutputDevices
        case outputDevicesLoaded([AudioOutputDevice])
        
        // Hotkey editing actions
        case task // initialise listeners
        case startSettingKaraokeHotKey
        case keyEvent(KeyEvent)
    }
    
    @Dependency(\.recording) var recording
    @Dependency(\.keyEventMonitor) var keyEventMonitor
    @Dependency(\.continuousClock) var clock
    
    var body: some ReducerOf<Self> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .binding:
                return .none
                
            case .loadAvailableOutputDevices:
                return .run { send in
                    let devices = await recording.getAvailableOutputDevices()
                    await send(.outputDevicesLoaded(devices))
                }
                
            case let .outputDevicesLoaded(devices):
                state.availableOutputDevices = devices
                return .none
                
            // MARK: - Hotkey Handling

            case .task:
                // Begin listening for key events
                return .run { send in
                    for try await event in await keyEventMonitor.listenForKeyPress() {
                        await send(.keyEvent(event))
                    }
                }
                .cancellable(id: "LiveSettingsKeyEvents", cancelInFlight: true)

            case .startSettingKaraokeHotKey:
                state.$isSettingKaraokeHotKey.withLock { $0 = true }
                return .none

            case let .keyEvent(keyEvent):
                guard state.isSettingKaraokeHotKey else { return .none }

                // ESC cancels capture
                if keyEvent.key == .escape {
                    state.$isSettingKaraokeHotKey.withLock { $0 = false }
                    state.currentKaraokeModifiers = []
                    return .none
                }

                // Accumulate modifiers while the user holds them
                state.currentKaraokeModifiers = keyEvent.modifiers.union(state.currentKaraokeModifiers)
                let currentMods = state.currentKaraokeModifiers

                if let key = keyEvent.key {
                    // finalise hotkey with key + modifiers
                    state.$hexSettings.withLock {
                        $0.karaokeHotKey.key = key
                        $0.karaokeHotKey.modifiers = currentMods
                    }
                    state.$isSettingKaraokeHotKey.withLock { $0 = false }
                    state.currentKaraokeModifiers = []
                } else if keyEvent.modifiers.isEmpty {
                    // Modifier-only shortcut (when all keys released)
                    state.$hexSettings.withLock {
                        $0.karaokeHotKey.key = nil
                        $0.karaokeHotKey.modifiers = currentMods
                    }
                    state.$isSettingKaraokeHotKey.withLock { $0 = false }
                    state.currentKaraokeModifiers = []
                }
                return .none
            }
        }
    }
}
