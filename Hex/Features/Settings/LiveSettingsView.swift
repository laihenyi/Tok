import ComposableArchitecture
import SwiftUI

struct LiveSettingsView: View {
    @Bindable var store: StoreOf<LiveSettingsFeature>
    
    var body: some View {
        Form {
            // --- Audio Mixing Section ---
            Section {
                // Enable audio mixing toggle
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Enable Audio Mixing", isOn: $store.hexSettings.enableAudioMixing)
                        Text("Mix microphone input with system output audio (for meetings)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "waveform.and.mic")
                }
                
                // Output device picker (only when mixing is enabled)
                if store.hexSettings.enableAudioMixing {
                    HStack {
                        Label {
                            Picker("Output Device", selection: $store.hexSettings.selectedOutputDeviceID) {
                                Text("System Default").tag(nil as String?)
                                ForEach(store.availableOutputDevices) { device in
                                    Text(device.name).tag(device.id as String?)
                                }
                            }
                            .pickerStyle(.menu)
                            .id(UUID()) // Force refresh when devices change
                        } icon: {
                            Image(systemName: "speaker.circle")
                        }
                        
                        Button(action: {
                            store.send(.loadAvailableOutputDevices)
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh available output devices")
                    }
                    
                    // Input gain slider
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Slider(value: $store.hexSettings.audioMixingInputGain, in: 0.0...2.0, step: 0.1) {
                                Text("Microphone Gain: \(store.hexSettings.audioMixingInputGain, specifier: "%.1f")")
                            }
                            Text("Adjust microphone volume in the mix")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "mic.badge.plus")
                    }
                    
                    // Output gain slider
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Slider(value: $store.hexSettings.audioMixingSystemAudioGain, in: 0.0...2.0, step: 0.1) {
                                Text("System Audio Gain: \(store.hexSettings.audioMixingSystemAudioGain, specifier: "%.1f")")
                            }
                            Text("Adjust system audio volume in the mix")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "speaker.badge.plus")
                    }
                    
                    // Show fallback note for selected output device not connected
                    if let selectedID = store.hexSettings.selectedOutputDeviceID, 
                       !store.availableOutputDevices.contains(where: { $0.id == selectedID }) {
                        Text("Selected output device not connected. System default will be used.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Audio Mixing")
            } footer: {
                if store.hexSettings.enableAudioMixing {
                    Text("Audio mixing captures both your microphone and system audio output. This is useful for transcribing meetings where you want to capture both your voice and other participants' audio. Note: Audio mixing is only used in karaoke mode, not for press-to-talk.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // --- Background Opacity Section ---
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: $store.hexSettings.backgroundOpacity, in: 0.0...1.0, step: 0.1) {
                            Text("Background Opacity: \(store.hexSettings.backgroundOpacity, specifier: "%.1f")")
                        }
                        Text("Adjust transparency of the karaoke view background")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "opacity")
                }
            } header: {
                Text("Karaoke View")
            } footer: {
                Text("Lower values make the background more transparent, allowing you to see content underneath the karaoke window.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.send(.loadAvailableOutputDevices)
        }
    }
}

#Preview {
    LiveSettingsView(store: Store(initialState: LiveSettingsFeature.State()) {
        LiveSettingsFeature()
    })
}
