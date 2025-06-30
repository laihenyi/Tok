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
                        Image(systemName: "speaker.wave.2.fill")
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
            
            // --- Karaoke View Section ---
            Section {
                // Background opacity slider
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
                    Image(systemName: "circle.lefthalf.fill")
                }

                // Font size slider
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: $store.hexSettings.karaokeFontSize, in: 12.0...72.0, step: 1.0) {
                            Text("Font Size: \(Int(store.hexSettings.karaokeFontSize))pt")
                        }
                        Text("Adjust the size of text in the karaoke view")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "textformat.size")
                }
            } header: {
                Text("Karaoke View")
            } footer: {
                Text("Lower opacity values make the background more transparent. Font size affects all text displayed in the karaoke window.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // --- Custom Theme Colors Section ---
            Section {
                CustomColorManagementView(customColors: $store.hexSettings.customThemeColors)
            } header: {
                Text("Custom Theme Colors")
            } footer: {
                Text("Create custom color themes by selecting text and background colors. These will appear in the karaoke view's theme picker.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // --- Karaoke Hot Key Section ---
            Section("Live View Hot Key") {
                let hotKey = store.hexSettings.karaokeHotKey
                let key = store.isSettingKaraokeHotKey ? nil : hotKey.key
                let modifiers = store.isSettingKaraokeHotKey ? store.currentKaraokeModifiers : hotKey.modifiers

                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingKaraokeHotKey)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.send(.startSettingKaraokeHotKey)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.send(.loadAvailableOutputDevices)
        }
        .task {
            await store.send(.task).finish()
        }
    }
}

// MARK: - Custom Theme Management View

struct CustomColorManagementView: View {
    @Binding var customColors: [String]
    @State private var customThemes: [CustomThemeOption] = []
    @State private var showingThemePicker = false
    @State private var selectedTextColor: Color = .black
    @State private var selectedBackgroundColor: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // List of existing custom themes
            if !customThemes.isEmpty {
                HStack(spacing: 12) {
                    ForEach(customThemes) { theme in
                        Button(action: {
                            removeTheme(theme)
                        }) {
                            Circle()
                                .fill(theme.backgroundColor)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Text("A")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(theme.textColor)
                                )
                                .overlay(
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.red)
                                        .background(Color.white, in: Circle())
                                        .offset(x: 12, y: -12)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Remove custom theme")
                    }
                }
                .padding(.bottom, 8)
            }

            // Add new theme section
            HStack(spacing: 12) {
                // Text color picker
                ColorPicker("Text Color", selection: $selectedTextColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 40, height: 32)

                Text("on")
                    .foregroundColor(.secondary)
                    .font(.caption)

                // Background color picker
                ColorPicker("Background Color", selection: $selectedBackgroundColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 40, height: 32)

                // Preview
                Circle()
                    .fill(selectedBackgroundColor)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text("A")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(selectedTextColor)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                Spacer()

                // Add button
                Button("Add Theme") {
                    addCustomTheme()
                }
            }
        }
        .onAppear {
            loadCustomThemes()
        }
        .onChange(of: customThemes) { _, _ in
            saveCustomThemes()
        }
    }

    private func addCustomTheme() {
        let newTheme = CustomThemeOption(
            textColorHex: $selectedTextColor.wrappedValue.toHex(),
            backgroundColorHex: $selectedBackgroundColor.wrappedValue.toHex()
        )

        // Check if theme already exists
        guard !customThemes.contains(where: {
            $0.textColorHex == newTheme.textColorHex &&
            $0.backgroundColorHex == newTheme.backgroundColorHex
        }) else { return }

        customThemes.append(newTheme)
    }

    private func removeTheme(_ theme: CustomThemeOption) {
        customThemes.removeAll { $0.id == theme.id }
    }

    private func loadCustomThemes() {
        // Clear existing themes first
        customThemes.removeAll()

        // Try to load themes from JSON format first
        if let jsonString = customColors.first,
           let data = jsonString.data(using: .utf8),
           let decodedThemes = try? JSONDecoder().decode([CustomThemeOption].self, from: data) {
            customThemes = decodedThemes
            return
        }

        // Convert old hex array format to new theme format if needed
        // This maintains backward compatibility
        if !customColors.isEmpty {
            // Convert existing hex colors to themes (text on white, white on color)
            for hexColor in customColors {
                if Color(hex: hexColor) != nil {
                    customThemes.append(CustomThemeOption(
                        textColorHex: hexColor,
                        backgroundColorHex: "#FFFFFF"
                    ))
                    customThemes.append(CustomThemeOption(
                        textColorHex: "#FFFFFF",
                        backgroundColorHex: hexColor
                    ))
                }
            }
            // Save in new format and clear old format
            saveCustomThemes()
        }
    }

    private func saveCustomThemes() {
        // Update the customColors binding to store theme data
        // We'll encode the themes as a JSON string in the first element
        if let data = try? JSONEncoder().encode(customThemes),
           let jsonString = String(data: data, encoding: .utf8) {
            customColors = [jsonString]
        }
    }
}
