import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ThemeOption: Identifiable, Hashable {
    let id = UUID()
    let text: Color
    let background: Color
}



struct ThemePickerView: View {
    @Binding var selectedText: Color
    @Binding var selectedBackground: Color
    let customColors: [String]
    @Environment(\.dismiss) private var dismiss

    private let defaultOptions: [ThemeOption] = [
        ThemeOption(text: .black, background: .white),
        ThemeOption(text: .white, background: .black),
        ThemeOption(text: .blue, background: .white),
        ThemeOption(text: .white, background: .blue),
        ThemeOption(text: .orange, background: .white),
        ThemeOption(text: .white, background: .orange),
        ThemeOption(text: .green, background: .white),
        ThemeOption(text: .white, background: .green),
        ThemeOption(text: .purple, background: .white),
        ThemeOption(text: .white, background: .purple),
    ]

    private let columns: [GridItem] = Array(repeating: .init(.fixed(44), spacing: 12), count: 3)

    // Computed property to combine default and custom options
    private var allOptions: [ThemeOption] {
        var options = defaultOptions

        // Parse custom themes from JSON if available
        if let jsonString = customColors.first,
           let data = jsonString.data(using: .utf8),
           let customThemes: [CustomThemeOption] = try? JSONDecoder().decode([CustomThemeOption].self, from: data) {

            for theme in customThemes {
                options.append(ThemeOption(
                    text: theme.textColor,
                    background: theme.backgroundColor
                ))
            }
        }

        return options
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Close button
            HStack {
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(allOptions) { option in
                    Button {
                        // Defer the binding updates to avoid "Publishing changes from within view updates"
                        DispatchQueue.main.async {
                            selectedText = option.text
                            selectedBackground = option.background
                        }
                        dismiss()
                    } label: {
                        Circle()
                            .fill(option.background)
                            .frame(width: 40, height: 40)
                            .overlay(
                                Text("A")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(option.text)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .frame(width: 180)
    }

    private var backgroundFill: Color {
#if os(macOS)
        return Color(NSColor.windowBackgroundColor).opacity(0.9)
#else
        return Color(.secondarySystemBackground).opacity(0.9)
#endif
    }
} 