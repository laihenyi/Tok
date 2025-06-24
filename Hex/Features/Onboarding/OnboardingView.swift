import ComposableArchitecture
import SwiftUI
import Sauce

// Child feature import for model selection view

struct OnboardingView: View {
  @Bindable var store: StoreOf<OnboardingFeature>
  
  var body: some View {
    VStack(spacing: 0) {
      // Header with progress
      VStack(spacing: 16) {
        HStack {
          Button("Back") {
            store.send(.previousStep)
          }
          .disabled(store.currentStep == .modelSelection)
          
          Spacer()
          
          Text("Step \(store.currentStep.rawValue + 1) of \(OnboardingFeature.State.OnboardingStep.allCases.count)")
            .font(.caption)
            .foregroundColor(.secondary)
          
          Spacer()
          
          Button("Skip") {
            store.send(.skipStep)
          }
          .disabled(store.currentStep == .test)
        }
        
        // Progress bar
        ProgressView(value: Double(store.currentStep.rawValue), total: Double(OnboardingFeature.State.OnboardingStep.allCases.count - 1))
          .progressViewStyle(LinearProgressViewStyle())
      }
      .padding(.horizontal, 24)
      .padding(.top, 20)
      
      Divider()
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
      
      // Content
      ScrollView {
        VStack(spacing: 24) {
          // Icon and title
          VStack(spacing: 12) {
            Image(systemName: store.currentStep.systemImage)
              .font(.system(size: 48))
              .foregroundColor(.accentColor)
            
            Text(store.currentStep.title)
              .font(.largeTitle)
              .fontWeight(.bold)
            
            Text(store.currentStep.description)
              .font(.body)
              .multilineTextAlignment(.center)
              .foregroundColor(.secondary)
              .padding(.horizontal, 32)
          }
          
          // Step content
          stepContent
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 24)
      }
      
      Divider()
      
      // Footer
      HStack {
        Spacer()
        
        switch store.currentStep {
        case .test:
          Button("Done") {
            store.send(.completeOnboarding)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!canContinue)
        default:
          Button("Continue") {
            store.send(.nextStep)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!canContinue)
        }
      }
      .padding(24)
    }
    .frame(width: 600, height: 700)
    .onAppear {
      store.send(.checkAllPermissions)
    }
  }
  
  @ViewBuilder
  private var stepContent: some View {
    switch store.currentStep {
    case .modelSelection:
      modelSelectionStep
    case .microphone:
      microphoneStep
    case .accessibility:
      accessibilityStep
    case .screenCapture:
      screenCaptureStep
    case .hotkey:
      hotkeyStep
    case .test:
      testStep
    }
  }
  
  private var modelSelectionStep: some View {
    ModelDownloadView(
      store: store.scope(
        state: \ .modelDownload,
        action: OnboardingFeature.Action.modelDownload
      )
    )
  }
  
  private var microphoneStep: some View {
    VStack(spacing: 24) {
      permissionStatusView(
        status: store.microphonePermission,
        grantedText: "Microphone access granted",
        deniedText: "Microphone access denied"
      )
      
      if !store.availableInputDevices.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          Text("Available Microphones")
            .font(.headline)
          
          ForEach(store.availableInputDevices, id: \.id) { device in
            HStack {
              Image(systemName: "mic")
              Text(device.name)
              Spacer()
              if store.hexSettings.selectedMicrophoneID == device.id {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundColor(.green)
              }
            }
            .padding(12)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            .onTapGesture {
              store.hexSettings.selectedMicrophoneID = device.id
            }
          }
        }
      }
      
      if store.microphonePermission != .granted {
        Button("Grant Microphone Access") {
          store.send(.requestMicrophonePermission)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
    }
  }
  
  private var accessibilityStep: some View {
    VStack(spacing: 24) {
      permissionStatusView(
        status: store.accessibilityPermission,
        grantedText: "Accessibility permissions granted",
        deniedText: "Accessibility permissions needed"
      )
      
      VStack(alignment: .leading, spacing: 12) {
        Text("What this enables:")
          .font(.headline)
        
        VStack(alignment: .leading, spacing: 8) {
          Text("• Global hotkey monitoring")
          Text("• Start recording from any app")
          Text("• Quick transcription access")
        }
        .foregroundColor(.secondary)
      }
      
      if store.accessibilityPermission != .granted {
        Button("Open Accessibility Settings") {
          store.send(.requestAccessibilityPermission)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
    }
  }
  
  private var screenCaptureStep: some View {
    VStack(spacing: 24) {
      permissionStatusView(
        status: store.screenCapturePermission,
        grantedText: "Screen capture access granted",
        deniedText: "Screen capture optional"
      )
      
      VStack(alignment: .leading, spacing: 12) {
        Text("Benefits of screen capture:")
          .font(.headline)
        
        VStack(alignment: .leading, spacing: 8) {
          Text("• Better transcription accuracy")
          Text("• Context-aware processing")
          Text("• Improved technical term recognition")
        }
        .foregroundColor(.secondary)
      }
      
      HStack(spacing: 12) {
        if store.screenCapturePermission != .granted {
          Button("Enable Screen Capture") {
            store.send(.requestScreenCapturePermission)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
        }
        
        Button("Skip for Now") {
          store.send(.nextStep)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
      }
    }
  }
  
  private var hotkeyStep: some View {
    VStack(spacing: 24) {
      HotkeySetupView { hotkey in
        store.send(.hotkeySet(hotkey))
      }
      
      if store.hexSettings.hotkey.key != nil {
        VStack(spacing: 12) {
          Text("Current Hotkey:")
            .font(.headline)
          
          Text(hotkeyDescription(hotkey: store.hexSettings.hotkey))
            .font(.title2)
            .fontWeight(.semibold)
            .padding(12)
            .background(Color.accentColor.opacity(0.1))
            .cornerRadius(8)
        }
      }
    }
  }
  
  private var testStep: some View {
    VStack(spacing: 16) {
      Text("Try speaking with your hotkey pressed. Your transcription will appear below.")
        .multilineTextAlignment(.center)
        .foregroundColor(.secondary)
      
      ZStack(alignment: .topLeading) {
        TextEditor(text: Binding(
          get: { store.testTranscription },
          set: { newValue in store.send(.updateTestTranscription(newValue)) }
        ))
          .frame(minHeight: 120)
          .padding(12)
          .background(Color.gray.opacity(0.1))
          .cornerRadius(8)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color.gray.opacity(0.3), lineWidth: 1)
          )
      }
    }
  }
  
  private func permissionStatusView(status: PermissionStatus, grantedText: String, deniedText: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundColor(status == .granted ? .green : .orange)
      
      Text(status == .granted ? grantedText : deniedText)
        .fontWeight(.medium)
      
      Spacer()
    }
    .padding(12)
    .background(status == .granted ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
    .cornerRadius(8)
  }
  
  private var canContinue: Bool {
    switch store.currentStep {
    case .modelSelection:
      return store.hexSettings.transcriptionModelWarmStatus == .warm
    case .microphone:
      return store.microphonePermission == .granted
    case .accessibility:
      return store.accessibilityPermission == .granted
    case .hotkey:
      return store.hexSettings.hotkey.key != nil
    default:
      return true
    }
  }
  
  private func hotkeyDescription(hotkey: HotKey) -> String {
    var parts: [String] = []
    
    if hotkey.modifiers.contains(.command) { parts.append("⌘") }
    if hotkey.modifiers.contains(.option) { parts.append("⌥") }
    if hotkey.modifiers.contains(.control) { parts.append("⌃") }
    if hotkey.modifiers.contains(.shift) { parts.append("⇧") }
    
    if let key = hotkey.key {
      parts.append(String(describing: key).uppercased())
    }
    
    return parts.joined(separator: " + ")
  }
}

struct FeatureRow: View {
  let icon: String
  let title: String
  let description: String
  
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundColor(.accentColor)
        .frame(width: 24)
      
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .fontWeight(.medium)
        
        Text(description)
          .font(.caption)
          .foregroundColor(.secondary)
      }
      
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color.gray.opacity(0.05))
    .cornerRadius(8)
  }
}

struct HotkeySetupView: View {
  let onHotkeySet: (HotKey) -> Void
  @State private var isListening = false
  @State private var currentModifiers: Modifiers = []
  @State private var detectedKey: Key?
  
  var body: some View {
    VStack(spacing: 16) {
      Text("Click the button below and press your desired hotkey combination")
        .multilineTextAlignment(.center)
        .foregroundColor(.secondary)
      
      Button(isListening ? "Press your hotkey..." : "Set Hotkey") {
        if isListening {
          // Stop listening
          isListening = false
        } else {
          // Start listening
          isListening = true
          currentModifiers = []
          detectedKey = nil
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .background(isListening ? Color.accentColor.opacity(0.1) : Color.clear)
      .cornerRadius(8)
      
      if isListening {
        Text("Press Escape to cancel")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      
      if !currentModifiers.isEmpty || detectedKey != nil {
        VStack(spacing: 8) {
          Text("Detected:")
            .font(.caption)
            .foregroundColor(.secondary)
          
          let hotkey = HotKey(key: detectedKey, modifiers: currentModifiers)
          Text(hotkeyDescription(hotkey: hotkey))
            .font(.title3)
            .fontWeight(.medium)
          
          if detectedKey != nil {
            Button("Use This Hotkey") {
              onHotkeySet(hotkey)
              isListening = false
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KeyEventReceived"))) { notification in
      guard isListening,
            let userInfo = notification.userInfo,
            let keyEvent = userInfo["keyEvent"] as? KeyEvent else { return }
      
      if keyEvent.key == .escape {
        isListening = false
        currentModifiers = []
        detectedKey = nil
      } else {
        currentModifiers = keyEvent.modifiers.union(currentModifiers)
        if let key = keyEvent.key {
          detectedKey = key
        }
      }
    }
  }
  
  private func hotkeyDescription(hotkey: HotKey) -> String {
    var parts: [String] = []
    
    if hotkey.modifiers.contains(.command) { parts.append("⌘") }
    if hotkey.modifiers.contains(.option) { parts.append("⌥") }
    if hotkey.modifiers.contains(.control) { parts.append("⌃") }
    if hotkey.modifiers.contains(.shift) { parts.append("⇧") }
    
    if let key = hotkey.key {
      parts.append(String(describing: key).uppercased())
    }
    
    return parts.joined(separator: " + ")
  }
} 