import ComposableArchitecture
import Foundation

@Reducer
struct LiveSettingsFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.hexSettings) var hexSettings: HexSettings
        var availableOutputDevices: [AudioOutputDevice] = []
    }
    
    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case loadAvailableOutputDevices
        case outputDevicesLoaded([AudioOutputDevice])
    }
    
    @Dependency(\.recording) var recording
    
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
            }
        }
    }
}
