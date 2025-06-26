import ComposableArchitecture
import SwiftUI

struct SettingsView: View {
	@Bindable var store: StoreOf<SettingsFeature>
	
	var body: some View {
		Form {
			// --- Permissions Section ---
			Section {
				// Microphone
				HStack {
					Label("Microphone", systemImage: "mic.fill")
					Spacer()
					switch store.microphonePermission {
					case .granted:
						Label("Granted", systemImage: "checkmark.circle.fill")
							.foregroundColor(.green)
							.labelStyle(.iconOnly)
					case .denied:
						Button("Request Permission") {
							store.send(.requestMicrophonePermission)
						}
						.buttonStyle(.borderedProminent)
						.tint(.blue)
					case .notDetermined:
						Button("Request Permission") {
							store.send(.requestMicrophonePermission)
						}
						.buttonStyle(.bordered)
					}
				}

				// Accessibility
				HStack {
					Label("Accessibility", systemImage: "accessibility")
					Spacer()
					switch store.accessibilityPermission {
					case .granted:
						Label("Granted", systemImage: "checkmark.circle.fill")
							.foregroundColor(.green)
							.labelStyle(.iconOnly)
					case .denied:
						Button("Request Permission") {
							store.send(.requestAccessibilityPermission)
						}
						.buttonStyle(.borderedProminent)
						.tint(.blue)
					case .notDetermined:
						Button("Request Permission") {
							store.send(.requestAccessibilityPermission)
						}
						.buttonStyle(.bordered)
					}
				}

			} header: {
				Text("Permissions")
			}
      
			// --- Input Device Selection Section ---
			if store.microphonePermission == .granted && !store.availableInputDevices.isEmpty {
				Section {
					// Input device picker
					HStack {
						Label {
							Picker("Input Device", selection: $store.hexSettings.selectedMicrophoneID) {
								Text("System Default").tag(nil as String?)
								ForEach(store.availableInputDevices) { device in
									Text(device.name).tag(device.id as String?)
								}
							}
							.pickerStyle(.menu)
							.id(UUID()) // Force refresh when devices change
						} icon: {
							Image(systemName: "mic.circle")
						}
						
						Button(action: {
							store.send(.loadAvailableInputDevices)
						}) {
							Image(systemName: "arrow.clockwise")
						}
						.buttonStyle(.borderless)
						.help("Refresh available input devices")
					}
					
					// Show fallback note for selected device not connected
					if let selectedID = store.hexSettings.selectedMicrophoneID, 
					   !store.availableInputDevices.contains(where: { $0.id == selectedID }) {
						Text("Selected device not connected. System default will be used.")
							.font(.caption)
							.foregroundColor(.secondary)
					}
				} header: {
					Text("Microphone Selection")
				}
			}
			
			// --- Audio Mixing Section ---
			if store.microphonePermission == .granted {
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
								Slider(value: $store.hexSettings.audioMixingOutputGain, in: 0.0...2.0, step: 0.1) {
									Text("System Audio Gain: \(store.hexSettings.audioMixingOutputGain, specifier: "%.1f")")
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
						Text("Audio mixing captures both your microphone and system audio output. This is useful for transcribing meetings where you want to capture both your voice and other participants' audio.")
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}
			}

			// --- Transcription Model Section ---
			Section("Transcription Model") {
				ModelDownloadView(store: store.scope(state: \.modelDownload, action: \.modelDownload)
				)
			}

			Label {
				Picker("Output Language", selection: $store.hexSettings.outputLanguage) {
					ForEach(store.languages, id: \.id) { language in
						Text(language.name).tag(language.code)
					}
				}
				.pickerStyle(.menu)
			} icon: {
				Image(systemName: "globe")
			}

			// --- Hot Key Section ---
			Section("Hot Key") {
				let hotKey = store.hexSettings.hotkey
				let key = store.isSettingHotKey ? nil : hotKey.key
				let modifiers = store.isSettingHotKey ? store.currentModifiers : hotKey.modifiers
				
				VStack(spacing: 12) {
					// Info text for full keyboard shortcut support
					if hotKey.key != nil {
						Text("You're using a full keyboard shortcut. Double-tap is recommended.")
							.font(.caption)
							.foregroundColor(.secondary)
							.frame(maxWidth: .infinity, alignment: .center)
					}
					
					// Hot key view
					HStack {
						Spacer()
						HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingHotKey)
							.animation(.spring(), value: key)
							.animation(.spring(), value: modifiers)
						Spacer()
					}
					.contentShape(Rectangle())
					.onTapGesture {
						store.send(.startSettingHotKey)
					}
				}
				
				// Double-tap toggle (for key+modifier combinations)
				if hotKey.key != nil {
					Label {
						Toggle("Use double-tap only", isOn: $store.hexSettings.useDoubleTapOnly)
						Text("Recommended for custom hotkeys to avoid interfering with normal usage")
							.font(.caption)
							.foregroundColor(.secondary)
					} icon: {
						Image(systemName: "hand.tap")
					}
				}
				
				// Minimum key time (for modifier-only shortcuts)
                if store.hexSettings.hotkey.key == nil {
                    Label {
                        Slider(value: $store.hexSettings.minimumKeyTime, in: 0.0...2.0, step: 0.1) {
                            Text("Ignore below \(store.hexSettings.minimumKeyTime, specifier: "%.1f")s")
                        }
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
			}

			// --- Sound Section ---
			Section {
				Label {
					Toggle("Sound Effects", isOn: $store.hexSettings.soundEffectsEnabled)
				} icon: {
					Image(systemName: "speaker.wave.2.fill")
				}
			} header: {
				Text("Sound")
			}

			// --- General Section ---
			Section {
				Label {
					Toggle("Open on Login",
					       isOn: Binding(
					       	get: { store.hexSettings.openOnLogin },
					       	set: { store.send(.toggleOpenOnLogin($0)) }
					       ))
				} icon: {
					Image(systemName: "arrow.right.circle")
				}

				Label {
					Toggle("Show Dock Icon", isOn: $store.hexSettings.showDockIcon)
				} icon: {
					Image(systemName: "dock.rectangle")
				}

				Label {
					Toggle("Use clipboard to insert", isOn: $store.hexSettings.useClipboardPaste)
					Text("Use clipboard to insert text. Fast but may not restore all clipboard content.\nTurn off to use simulated keypresses. Slower, but doesn't need to restore clipboard")
				} icon: {
					Image(systemName: "doc.on.doc.fill")
				}
				
				Label {
					Toggle("Copy to clipboard", isOn: $store.hexSettings.copyToClipboard)
					Text("Copy transcription text to clipboard in addition to pasting it")
				} icon: {
					Image(systemName: "doc.on.clipboard")
				}
                
                Label {
                    Toggle("Disable auto-capitalization", isOn: $store.hexSettings.disableAutoCapitalization)
                    Text("Disable automatic capitalization in transcriptions")
                } icon: {
                    Image(systemName: "textformat.abc")
                }

				Label {
					Toggle(
						"Prevent System Sleep while Recording",
						isOn: Binding(
							get: { store.hexSettings.preventSystemSleep },
							set: { store.send(.togglePreventSystemSleep($0)) }
						))
				} icon: {
					Image(systemName: "zzz")
				}
                
                Label {
                    Toggle(
                        "Pause Media while Recording",
                        isOn: Binding(
                            get: { store.hexSettings.pauseMediaOnRecord },
                            set: { store.send(.togglePauseMediaOnRecord($0)) }
                        ))
                } icon: {
                    Image(systemName: "pause")
                }
			} header: {
				Text("General")
			}
		}
		.formStyle(.grouped)
		.task {
			await store.send(.task).finish()
		}
	}
}