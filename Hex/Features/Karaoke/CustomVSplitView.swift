import SwiftUI
import AppKit

// MARK: - Custom Split View with Tintable Divider

/// A thin divider, vertical split view whose divider can be tinted.
final class ColorSplitView: NSSplitView {
    /// The colour used when drawing the divider.
    var dividerTint: NSColor = .systemPink {
        didSet { needsDisplay = true }
    }

    override func drawDivider(in rect: NSRect) {
        dividerTint.setFill()
        rect.fill()
    }
}

/// A SwiftUI wrapper around `ColorSplitView` that hosts two SwiftUI sub-views (top & bottom)
/// and exposes a bindable divider colour.
struct CustomVSplitView<Top: View, Bottom: View>: NSViewRepresentable {
    @Binding var dividerColor: Color
    @Binding var splitRatio: CGFloat

    let top: Top
    let bottom: Bottom

    init(
        dividerColor: Binding<Color>,
        splitRatio: Binding<CGFloat>,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self._dividerColor = dividerColor
        self._splitRatio = splitRatio
        self.top = top()
        self.bottom = bottom()
    }

    func makeNSView(context: Context) -> ColorSplitView {
        let splitView = ColorSplitView()
        splitView.isVertical = false       // Top/Bottom layout
        splitView.dividerStyle = .thin

        // Host SwiftUI content inside AppKit containers
        let topHost = NSHostingView(rootView: top)
        let bottomHost = NSHostingView(rootView: bottom)

        splitView.addArrangedSubview(topHost)
        splitView.addArrangedSubview(bottomHost)

        // Initial divider tint and position
        splitView.dividerTint = nsColor(from: dividerColor)
        DispatchQueue.main.async {
            splitView.setPosition(splitView.bounds.height * splitRatio, ofDividerAt: 0)
        }

        return splitView
    }

    func updateNSView(_ splitView: ColorSplitView, context: Context) {
        // Update tint
        splitView.dividerTint = nsColor(from: dividerColor)

        // Update hosted SwiftUI content
        if let topHost = splitView.arrangedSubviews.first as? NSHostingView<Top> {
            topHost.rootView = top
        }
        if let bottomHost = splitView.arrangedSubviews.last as? NSHostingView<Bottom> {
            bottomHost.rootView = bottom
        }
    }

    // Helper to convert `Color` ➜ `NSColor` in a safe way.
    private func nsColor(from color: Color) -> NSColor {
        #if os(macOS)
        if let cg = color.cgColor {
            return NSColor(cgColor: cg) ?? .clear
        }
        #endif
        return .clear
    }
}
