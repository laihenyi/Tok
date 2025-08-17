//
//  AppFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import ComposableArchitecture
import Dependencies
import SwiftUI

@Reducer
struct AppFeature {
  enum ActiveTab: Equatable {
    case settings
    // case history  // DISABLED: History功能暫時停用
    case about
    case aiEnhancement
    case developer
  }

  @ObservableState
  struct State {
    var transcription: TranscriptionFeature.State = .init()
    var settings: SettingsFeature.State = .init()
    // var history: HistoryFeature.State = .init()  // DISABLED: History功能暫時停用
    var onboarding: OnboardingFeature.State = .init()
    var developer: DeveloperFeature.State = .init()
    var activeTab: ActiveTab = .settings
    var shouldShowOnboarding: Bool = false
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    // case history(HistoryFeature.Action)  // DISABLED: History功能暫時停用
    case developer(DeveloperFeature.Action)
    case onboarding(OnboardingFeature.Action)
    case setActiveTab(ActiveTab)
    case checkShouldShowOnboarding
    case dismissOnboarding
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.transcription, action: \.transcription) {
      TranscriptionFeature()
    }

    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    // DISABLED: History功能暫時停用
    // Scope(state: \.history, action: \.history) {
    //   HistoryFeature()
    // }

    Scope(state: \.developer, action: \.developer) {
      DeveloperFeature()
    }

    Scope(state: \.onboarding, action: \.onboarding) {
      OnboardingFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none
      case .transcription:
        return .none
      // DISABLED: History功能暫時停用
      // case .settings(.openHistory):
      //   state.activeTab = .history
      //   return .none
      case .settings:
        return .none
      // case .history:
      //   return .none
      case .developer:
        return .none
      case .onboarding(.completeOnboarding):
        state.shouldShowOnboarding = false
        return .none
      case .onboarding:
        return .none
      case let .setActiveTab(tab):
        state.activeTab = tab
        return .none
      case .checkShouldShowOnboarding:
        state.shouldShowOnboarding = !state.onboarding.hexSettings.hasCompletedOnboarding
        return .none
      case .dismissOnboarding:
        state.shouldShowOnboarding = false
        return .none
      }
    }
  }
}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $store.activeTab) {
        Button {
          store.send(.setActiveTab(.settings))
        } label: {
          Label("Settings", systemImage: "gearshape")
        }.buttonStyle(.plain)
          .tag(AppFeature.ActiveTab.settings)

        Button {
          store.send(.setActiveTab(.aiEnhancement))
        } label: {
          Label("AI Enhancement", systemImage: "brain")
        }.buttonStyle(.plain)
          .tag(AppFeature.ActiveTab.aiEnhancement)

        // DISABLED: History功能暫時停用
        // Button {
        //   store.send(.setActiveTab(.history))
        // } label: {
        //   Label("History", systemImage: "clock")
        // }.buttonStyle(.plain)
        //   .tag(AppFeature.ActiveTab.history)
          
        Button {
          store.send(.setActiveTab(.about))
        } label: {
          Label("About", systemImage: "info.circle")
        }.buttonStyle(.plain)
          .tag(AppFeature.ActiveTab.about)

        // Show Developer tab only when developer mode is enabled in settings
        if store.settings.hexSettings.developerModeEnabled {
          Button {
            store.send(.setActiveTab(.developer))
          } label: {
            Label("Developer", systemImage: "hammer")
          }.buttonStyle(.plain)
            .tag(AppFeature.ActiveTab.developer)
        }
      }
    } detail: {
      switch store.state.activeTab {
      case .settings:
        SettingsView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Settings")
      case .aiEnhancement:
        AIEnhancementView(store: store.scope(state: \.settings.aiEnhancement, action: \.settings.aiEnhancement))
          .navigationTitle("AI Enhancement")
      // DISABLED: History功能暫時停用
      // case .history:
      //   HistoryView(store: store.scope(state: \.history, action: \.history))
      //     .navigationTitle("History")
      case .about:
        AboutView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("About")
      case .developer:
        DeveloperView(store: store.scope(state: \.developer, action: \.developer))
          .navigationTitle("Developer")
      }
    }
    .onAppear {
      store.send(.checkShouldShowOnboarding)
    }
    .sheet(isPresented: $store.shouldShowOnboarding) {
      OnboardingView(store: store.scope(state: \.onboarding, action: \.onboarding))
        .interactiveDismissDisabled(true)
    }
  }
}
