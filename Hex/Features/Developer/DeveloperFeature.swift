import ComposableArchitecture
import SwiftUI

@Reducer
struct DeveloperFeature {
    @ObservableState
    struct State {
        @Shared(.hexSettings) var hexSettings: HexSettings
    }

    enum Action {
        case resetOnboarding
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .resetOnboarding:
                state.$hexSettings.withLock { $0.hasCompletedOnboarding = false }
                return .none
            }
        }
    }
}

struct DeveloperView: View {
    @Bindable var store: StoreOf<DeveloperFeature>

    var body: some View {
        Form {
            Section("Onboarding") {
                Button("Reset Onboarding") {
                    store.send(.resetOnboarding)
                }
                .buttonStyle(.bordered)
                Text("Onboarding will be shown the next time you open the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
} 