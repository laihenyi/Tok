import SwiftUI
import ComposableArchitecture
import AppKit

/// Window content for the live, karaoke-style transcription view.
struct KaraokeView: View {
    @Bindable var store: StoreOf<KaraokeFeature>
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

    /// Copy the entire visible transcript to the clipboard.
    private func copyAllText() {
        let allText = store.lines
            .filter { $0.type == .transcription || $0.type == .liveText }
            .map { $0.text }
            .joined(separator: " ")

        guard !allText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allText, forType: .string)
    }

    var body: some View {
        ZStack {
            // MARK: – Dynamic translucent background
            if backgroundColor == .black {
                CheckerboardBackground()
                    .opacity(store.hexSettings.backgroundOpacity)
            } else {
                backgroundColor
                    .opacity(store.hexSettings.backgroundOpacity)
                    .ignoresSafeArea()
            }

            // MARK: – Main split view (transcription ↕︎ AI)
            CustomVSplitView(
                dividerColor: Binding(
                    get: { highlightColor.opacity(0.3) },
                    set: { _ in }
                ),
                splitRatio: .constant(store.splitRatio)
            ) {
                // ================= TOP PANE =================
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 8) {
                        // Segment control for transcript / background
                        Picker("", selection: $store.selectedTopPaneTab.sending(\.setSelectedTopPaneTab)) {
                            Text("Transcription").tag(KaraokeFeature.TopPaneTab.transcription)
                            Text("Background").tag(KaraokeFeature.TopPaneTab.background)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                        .padding(.top, 8)
                        .tint(highlightColor)

                        if store.selectedTopPaneTab == .transcription {
                            transcriptionScrollView
                        } else {
                            backgroundTextView
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // ---------- Header toolbar (theme, pin, copy, start/stop) ----------
                    HStack {
                        // Theme picker button
                        Button(action: { showingThemePicker.toggle() }) {
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
                                customColors: store.hexSettings.customThemeColors
                            )
                            .onDisappear { showingThemePicker = false }
                        }

                        // Pin on top toggle
                        Button(action: { togglePinOnTop() }) {
                            Image(systemName: isPinnedOnTop ? "pin.fill" : "pin")
                                .foregroundColor(isPinnedOnTop ? highlightColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isPinnedOnTop ? "Unpin from top" : "Pin on top")

                        // Copy transcript
                        Button(action: { copyAllText() }) {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy all text")

                        Spacer()

                        // Start / Stop transcription
                        if store.isTranscribing {
                            Button("Stop") { store.send(.stopTapped) }
                                .keyboardShortcut(.escape, modifiers: [])
                        } else {
                            Button("Start") { store.send(.startTapped) }
                                .keyboardShortcut(.space, modifiers: [])
                        }
                    }
                    .padding([.top, .leading, .trailing], 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backgroundColor == .black ? Color.clear : backgroundColor.opacity(store.hexSettings.backgroundOpacity))
            } bottom: {
                // ================= LOWER AI PANE =================
                VStack(alignment: .center, spacing: 8) {
                    Picker("", selection: $store.selectedTab.sending(\.setSelectedTab)) {
                        Text("Response").tag(KaraokeFeature.Tab.response)
                        Text("Prompt").tag(KaraokeFeature.Tab.prompt)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    .padding(.top, 8)
                    .tint(highlightColor)

                    if store.selectedTab == .prompt {
                        TextEditor(text: $store.promptText.sending(\.setPrompt))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(highlightColor)
                            .border(highlightColor.opacity(0.2))
                            .padding()
                    } else {
                        ScrollView {
                            Text(store.aiResponse.isEmpty ? "" : store.aiResponse)
                                .font(.system(size: store.hexSettings.karaokeFontSize, weight: .bold, design: .rounded))
                                .foregroundColor(highlightColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .textSelection(.enabled)
                                .contextMenu {
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(store.aiResponse, forType: .string)
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
        // Persist & restore colours and window level
        .onAppear {
            highlightColor = Color.themeColor(from: storedHighlightName)
            backgroundColor = Color.themeColor(from: storedBackgroundName)

            let targetLevel: NSWindow.Level = isPinnedOnTop ? .screenSaver : .normal
            appDelegate.setKaraokeWindowLevel(targetLevel)
        }
        .onChange(of: highlightColor) { _, newValue in storedHighlightName = newValue.themeName }
        .onChange(of: backgroundColor) { _, newValue in storedBackgroundName = newValue.themeName }
        .onDisappear {
            if store.isTranscribing {
                store.send(.stopTapped)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Transcription Scroll View
    private var transcriptionScrollView: some View {
        AutoTrackingScrollView(trackedValue: store.lines.count) {
            VStack(spacing: 12) {
                ForEach(store.lines) { line in
                    Group {
                        switch line.type {
                        case .transcription:
                            Text(line.text)
                                .font(.system(size: store.hexSettings.karaokeFontSize, weight: .bold, design: .rounded))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(highlightColor)
                                .animation(.easeInOut(duration: 0.3), value: line.isHighlighted)
                                .textSelection(.enabled)
                        
                        case .liveText:
                            Text(line.text)
                                .font(.system(size: store.hexSettings.karaokeFontSize, weight: .bold, design: .rounded))
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
            .padding()
        }
    }
    
    // MARK: - Background Text View
    private var backgroundTextView: some View {
        TextEditor(text: $store.backgroundText.sending(\.setBackgroundText))
            .font(.system(size: 14))
            .padding()
            .background(Color(.textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .padding()
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