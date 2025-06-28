import SwiftUI
import ComposableArchitecture
import AppKit

/// Window content for the live, karaoke-style transcription view.
struct KaraokeView: View {
    let store: StoreOf<KaraokeFeature>
    let appDelegate: HexAppDelegate

    // Persisted theme colours
    @AppStorage("karaokeHighlightColor") private var storedHighlightName: String = "pink"
    @AppStorage("karaokeBackgroundColor") private var storedBackgroundName: String = "black"
    // Persisted pinned status
    @AppStorage("karaokeIsPinnedOnTop") private var isPinnedOnTop: Bool = false

    // Currently selected highlight colour for active lyrics
    @State private var highlightColor: Color = .pink
    @State private var backgroundColor: Color = .black
    @State private var showingThemePicker = false
    
    /// Determines if the current background color is considered dark
    private var isDarkBackground: Bool {
        // Consider black and other dark colors as dark backgrounds
        backgroundColor == .black ||
        backgroundColor == .gray ||
        backgroundColor.description.contains("dark") ||
        // For custom colors, check if they're closer to black than white
        (backgroundColor != .white && backgroundColor != .yellow && backgroundColor != .cyan && backgroundColor != .mint && backgroundColor != .pink)
    }

    /// Toggle the window's pin-on-top status
    private func togglePinOnTop() {
        isPinnedOnTop.toggle()

        // Update window level through app delegate
        let targetLevel: NSWindow.Level = isPinnedOnTop ? .screenSaver : .normal
        appDelegate.setKaraokeWindowLevel(targetLevel)
    }

    /// Copy all transcription text to clipboard
    private func copyAllText(viewStore: ViewStore<KaraokeFeature.State, KaraokeFeature.Action>) {
        let allText = viewStore.lines
            .filter { $0.type == .transcription || $0.type == .liveText }
            .map { $0.text }
            .joined(separator: " ")

        if !allText.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(allText, forType: .string)
        }
    }

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            ZStack {
                // Translucent dynamic background: checkerboard for black; colour with
                // configurable opacity otherwise. Keeping some transparency lets the
                // content underneath the window show through.
                if backgroundColor == .black {
                    CheckerboardBackground()
                        .opacity(viewStore.hexSettings.backgroundOpacity)
                } else {
                    backgroundColor
                        .opacity(viewStore.hexSettings.backgroundOpacity)
                        .ignoresSafeArea()
                }

                CustomVSplitView(
                    dividerColor: Binding(
                        get: { highlightColor.opacity(0.3) },
                        set: { _ in }
                    ),
                    splitRatio: .constant(viewStore.splitRatio)
                ) {
                    // MARK: – Upper transcription pane
                    ZStack(alignment: .topTrailing) {
                        // Scrollable list of lyric lines, newest at bottom
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 8) {
                                    ForEach(viewStore.lines) { line in
                                        Group {
                                        switch line.type {
                                            case .transcription:
                                                Text(line.text)
                                                    .font(.system(size: viewStore.hexSettings.karaokeFontSize, weight: .bold, design: .rounded))
                                                    .multilineTextAlignment(.center)
                                                    .foregroundStyle(highlightColor)
                                                    .animation(.easeInOut(duration: 0.3), value: line.isHighlighted)
                                                    .textSelection(.enabled)

                                            case .liveText:
                                                Text(line.text)
                                                    .font(.system(size: viewStore.hexSettings.karaokeFontSize, weight: .bold, design: .rounded))
                                                    .multilineTextAlignment(.center)
                                                    .foregroundStyle(highlightColor)
                                                    .opacity(line.isHighlighted ? 1.0 : 0.6)
                                                    .animation(.easeInOut(duration: 0.2), value: line.isHighlighted)
                                                    .overlay(
                                                        // Add a subtle pulsing effect to indicate live text
                                                        RoundedRectangle(cornerRadius: 6)
                                                            .stroke(highlightColor.opacity(0.3), lineWidth: 1)
                                                            .opacity(line.isHighlighted ? 1.0 : 0.0)
                                                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: line.isHighlighted)
                                                    )
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .textSelection(.enabled)
                                            
                                            case .separator:
                                                ChunkSeparatorView(timestamp: line.timestamp ?? Date(), highlightColor: highlightColor, status: line.processingStatus)
                                            
                                            case .sessionStart:
                                                SessionBoundaryView(type: .start, timestamp: line.timestamp ?? Date(), highlightColor: highlightColor)
                                            
                                            case .sessionEnd:
                                                SessionBoundaryView(type: .end, timestamp: line.timestamp ?? Date(), highlightColor: highlightColor)
                                            }
                                        }
                                        .id(line.id)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                                .onChange(of: viewStore.lines.last?.id) { _, newID in
                                    if let newID {
                                        proxy.scrollTo(newID, anchor: .bottom)
                                    }
                                }
                            }
                        }

                        // Toolbar overlay
                        HStack {
                            // Theme picker button
                            Button(action: { showingThemePicker.toggle() }) {
                                // Show current theme preview
                                Circle()
                                    .fill(backgroundColor)
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Text("A")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(highlightColor)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Choose theme colours")
                            .popover(isPresented: $showingThemePicker, arrowEdge: .top) {
                                ThemePickerView(
                                    selectedText: $highlightColor,
                                    selectedBackground: $backgroundColor,
                                    customColors: viewStore.hexSettings.customThemeColors
                                )
                                .onDisappear { showingThemePicker = false }
                            }

                            // Pin button
                            Button(action: { togglePinOnTop() }) {
                                Image(systemName: isPinnedOnTop ? "pin.fill" : "pin")
                                    .foregroundColor(isPinnedOnTop ? highlightColor : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(isPinnedOnTop ? "Unpin from top" : "Pin on top")

                            // Copy all text button
                            Button(action: { copyAllText(viewStore: viewStore) }) {
                                Image(systemName: "doc.on.doc")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy all text")

                            Spacer()

                            // Start / Stop button
                            if viewStore.isTranscribing {
                                Button("Stop") { viewStore.send(.stopTapped) }
                                    .keyboardShortcut(.escape, modifiers: [])
                            } else {
                                Button("Start") { viewStore.send(.startTapped) }
                                    .keyboardShortcut(.space, modifiers: [])
                            }
                        }
                        .padding([.top, .leading, .trailing], 12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Keep a subtle coloured backdrop with transparency for the lower pane.
                    .background(backgroundColor == .black ? Color.clear : backgroundColor.opacity(viewStore.hexSettings.backgroundOpacity))
                } bottom: {
                    // MARK: – Lower AI pane
                    VStack(alignment: .center, spacing: 8) {
                        Picker("", selection: viewStore.binding(get: { $0.selectedTab }, send: KaraokeFeature.Action.setSelectedTab)) {
                            Text("Response").tag(KaraokeFeature.Tab.response)
                            Text("Prompt").tag(KaraokeFeature.Tab.prompt)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                        .padding(.top, 8)
                        .tint(highlightColor)

                        if viewStore.selectedTab == .prompt {
                            TextEditor(text: viewStore.binding(get: { $0.promptText }, send: KaraokeFeature.Action.setPrompt))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(highlightColor)
                                .border(highlightColor.opacity(0.2))
                                .padding()
                        } else {
                            ScrollView {
                                Text(viewStore.aiResponse.isEmpty ? "" : viewStore.aiResponse)
                                    .font(.system(size: viewStore.hexSettings.karaokeFontSize, weight: .bold, design: .rounded))
                                    .foregroundColor(highlightColor)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                                    .textSelection(.enabled)
                                    .contextMenu {
                                        Button("Copy") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(viewStore.aiResponse, forType: .string)
                                        }
                                    }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 500, minHeight: 400)
            .preferredColorScheme(isDarkBackground ? .dark : .light)
            // Sync the in-memory colours with the persisted values and set window level
            .onAppear {
                highlightColor = Color.themeColor(from: storedHighlightName)
                backgroundColor = Color.themeColor(from: storedBackgroundName)

                // Set window level based on pin status: .normal by default, .screenSaver when pinned
                let targetLevel: NSWindow.Level = isPinnedOnTop ? .screenSaver : .normal
                appDelegate.setKaraokeWindowLevel(targetLevel)
            }
            // Ensure the correct window level is applied on launch as well.
            .onChange(of: highlightColor) { _, newValue in
                storedHighlightName = newValue.themeName
            }
            .onChange(of: backgroundColor) { _, newValue in
                storedBackgroundName = newValue.themeName
            }
            // Ensure recording stops and system-level hotkey is re-enabled when the window is closed
            .onDisappear {
                if viewStore.isTranscribing {
                    viewStore.send(.stopTapped)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }
}

// MARK: - Separator Views

struct ChunkSeparatorView: View {
    let timestamp: Date
    let highlightColor: Color
    let status: KaraokeFeature.Line.ProcessingStatus?
    
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }
    
    var body: some View {
        HStack {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(highlightColor.opacity(0.3))
            
            VStack(spacing: 2) {
                Text(timeFormatter.string(from: timestamp))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(highlightColor.opacity(0.5))

                if let status {
                    Text(status == .transcribing ? "Transcribing…" : "Enhancing…")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(highlightColor.opacity(0.7))
                }
            }
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(highlightColor.opacity(0.1))
            )
            
            Rectangle()
                .frame(height: 1)
                .foregroundColor(highlightColor.opacity(0.3))
        }
        .padding(.vertical, 4)
    }
}

struct SessionBoundaryView: View {
    enum BoundaryType {
        case start, end
        
        var label: String {
            switch self {
            case .start: return "SESSION START"
            case .end: return "SESSION END"
            }
        }
    }
    
    let type: BoundaryType
    let timestamp: Date
    let highlightColor: Color
    
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }
    
    var body: some View {
        HStack {
            Rectangle()
                .frame(height: 2)
                .foregroundColor(highlightColor.opacity(0.5))
            
            VStack(spacing: 2) {
                Text(type.label)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(highlightColor)
                
                Text(timeFormatter.string(from: timestamp))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(highlightColor.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(highlightColor.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(highlightColor.opacity(0.3), lineWidth: 1)
                    )
            )
            
            Rectangle()
                .frame(height: 2)
                .foregroundColor(highlightColor.opacity(0.5))
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Theme <-> String helpers

fileprivate extension Color {
    /// Returns a human-readable name for the limited palette used in the theme picker.
    var themeName: String {
        switch self {
        case .black:   return "black"
        case .white:   return "white"
        case .blue:    return "blue"
        case .orange:  return "orange"
        case .green:   return "green"
        case .purple:  return "purple"
        case .pink:    return "pink" // default / fallback
        default:       return "pink"
        }
    }

    /// Converts a stored colour name back into a `Color`.
    static func themeColor(from name: String) -> Color {
        switch name {
        case "black":   return .black
        case "white":   return .white
        case "blue":    return .blue
        case "orange":  return .orange
        case "green":   return .green
        case "purple":  return .purple
        case "pink":    return .pink
        default:         return .pink
        }
    }
}