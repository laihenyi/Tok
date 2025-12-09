import ComposableArchitecture
import Dependencies
import Foundation
import SwiftUI
import AVFoundation
import ApplicationServices

@Reducer
struct OnboardingFeature {
  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    
    var currentStep: OnboardingStep = .modelSelection
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var screenCapturePermission: PermissionStatus = .notDetermined
    var isComplete: Bool = false
    var hasCompletedOnboarding: Bool = false
    var testTranscription: String = ""
    var availableInputDevices: [AudioInputDevice] = []
    // Child state: model selection & download
    var modelDownload: ModelDownloadFeature.State = .init()
    
    enum OnboardingStep: Int, CaseIterable {
      case modelSelection = 0
      case microphone = 1
      case accessibility = 2
      case screenCapture = 3
      case hotkey = 4
      case test = 5
      
      var title: LocalizedStringKey {
        switch self {
        case .modelSelection: return "onboarding.step.modelSelection.title"
        case .microphone: return "onboarding.step.microphone.title"
        case .accessibility: return "onboarding.step.accessibility.title"
        case .screenCapture: return "onboarding.step.screenCapture.title"
        case .hotkey: return "onboarding.step.hotkey.title"
        case .test: return "onboarding.step.test.title"
        }
      }

      var description: LocalizedStringKey {
        switch self {
        case .modelSelection:
          return "onboarding.step.modelSelection.description"
        case .microphone:
          return "onboarding.step.microphone.description"
        case .accessibility:
          return "onboarding.step.accessibility.description"
        case .screenCapture:
          return "onboarding.step.screenCapture.description"
        case .hotkey:
          return "onboarding.step.hotkey.description"
        case .test:
          return "onboarding.step.test.description"
        }
      }
      
      var systemImage: String {
        switch self {
        case .modelSelection: return "square.and.arrow.down"
        case .microphone: return "mic"
        case .accessibility: return "key"
        case .screenCapture: return "camera"
        case .hotkey: return "keyboard"
        case .test: return "play.circle"
        }
      }
    }
  }
  
  @Dependency(\.recording) var recording
  @Dependency(\.screenCapture) var screenCapture
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  
  @CasePathable
  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case nextStep
    case previousStep
    case skipStep
    case requestMicrophonePermission
    case requestAccessibilityPermission
    case requestScreenCapturePermission
    case microphonePermissionUpdated(PermissionStatus)
    case accessibilityPermissionUpdated(PermissionStatus)
    case screenCapturePermissionUpdated(PermissionStatus)
    case checkAllPermissions
    case completeOnboarding
    case updateTestTranscription(String)
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice])
    case hotkeySet(HotKey)
    // Child action
    case modelDownload(ModelDownloadFeature.Action)
  }
  
  var body: some ReducerOf<Self> {
    BindingReducer()
    
    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }
    
    Reduce { state, action -> Effect<Action> in
      switch action {
      case .binding, .modelDownload:
        return .none
        
      case .nextStep:
        let allSteps = OnboardingFeature.State.OnboardingStep.allCases
        if let currentIndex = allSteps.firstIndex(of: state.currentStep),
           currentIndex < allSteps.count - 1 {
          state.currentStep = allSteps[currentIndex + 1]
          
          // Check permissions when entering relevant steps
          switch state.currentStep {
          case .microphone:
            return .send(.loadAvailableInputDevices)
          case .accessibility, .screenCapture:
            return .send(.checkAllPermissions)
          default:
            return .none
          }
        }
        return .none
        
      case .previousStep:
        let allSteps = OnboardingFeature.State.OnboardingStep.allCases
        if let currentIndex = allSteps.firstIndex(of: state.currentStep),
           currentIndex > 0 {
          state.currentStep = allSteps[currentIndex - 1]
        }
        return .none
        
      case .skipStep:
        return .send(.nextStep)
        
      case .requestMicrophonePermission:
        NSLog("🎙️ [ONBOARDING] requestMicrophonePermission action received")
        return .run { [recording] send in
          NSLog("🎙️ [ONBOARDING] Starting microphone access request...")
          let granted = await recording.requestMicrophoneAccess()
          NSLog("🎙️ [ONBOARDING] Microphone access result: \(granted)")
          await send(.microphonePermissionUpdated(granted ? .granted : .denied))
        }
        
      case .requestAccessibilityPermission:
        return .run { send in
          let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
          let granted = AXIsProcessTrustedWithOptions(options as CFDictionary)
          await send(.accessibilityPermissionUpdated(granted ? .granted : .denied))
        }
        
      case .requestScreenCapturePermission:
        return .run { send in
          // Use CGRequestScreenCaptureAccess to properly request permission
          // This will open System Settings if permission is not granted
          let granted = CGRequestScreenCaptureAccess()
          await send(.screenCapturePermissionUpdated(granted ? .granted : .notDetermined))
        }
        
      case let .microphonePermissionUpdated(status):
        state.microphonePermission = status
        if status == .granted {
          // Auto advance after short delay
          return .run { send in
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            await send(.nextStep)
          }
        }
        return .none
        
      case let .accessibilityPermissionUpdated(status):
        state.accessibilityPermission = status
        if status == .granted {
          return .run { send in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await send(.nextStep)
          }
        }
        return .none
        
      case let .screenCapturePermissionUpdated(status):
        state.screenCapturePermission = status
        if status == .granted {
          state.$hexSettings.withLock { $0.enableScreenCapture = true }
          return .run { send in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await send(.nextStep)
          }
        }
        return .none
        
      case .checkAllPermissions:
        return .run { send in
          // Check microphone
          let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
          let micPermission: PermissionStatus = switch micAuthStatus {
          case .authorized: .granted
          case .denied: .denied
          case .restricted: .denied
          case .notDetermined: .notDetermined
          @unknown default: .notDetermined
          }
          await send(.microphonePermissionUpdated(micPermission))

          // Check accessibility
          let accPermission: PermissionStatus = AXIsProcessTrusted() ? .granted : .denied
          await send(.accessibilityPermissionUpdated(accPermission))

          // Check screen capture permission using CGPreflightScreenCaptureAccess
          // This checks permission status without triggering a system prompt
          let hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
          await send(.screenCapturePermissionUpdated(hasScreenCapturePermission ? .granted : .notDetermined))
        }
        
      case .completeOnboarding:
        state.hasCompletedOnboarding = true
        state.isComplete = true
        state.$hexSettings.withLock { $0.hasCompletedOnboarding = true }
        return .none
        
      case let .updateTestTranscription(text):
        state.testTranscription = text
        return .none
        
      case .loadAvailableInputDevices:
        return .run { send in
          let devices = await recording.getAvailableInputDevices()
          await send(.availableInputDevicesLoaded(devices))
        }
        
      case let .availableInputDevicesLoaded(devices):
        state.availableInputDevices = devices
        return .none
        
      case let .hotkeySet(hotkey):
        state.$hexSettings.withLock { $0.hotkey = hotkey }
        return .send(.nextStep)
      }
    }
  }
}

 