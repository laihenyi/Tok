import SwiftUI

/// A `ScrollView` that supports automatic scrolling to the bottom but disables it when the user
/// manually scrolls up. Auto-scrolling is re-enabled when the user scrolls back to the bottom.
public struct AutoTrackingScrollView<T: Equatable, Content: View>: View {
    /// The value to track for changes. When this value changes, the view scrolls to the bottom if auto-scrolling is enabled.
    let trackedValue: T

    /// The content to display in the scroll view.
    @ViewBuilder let content: () -> Content

    // MARK: – State & constants (macOS 14 +)
    @State private var isAutoScrollEnabled = true
    @State private var scrollID: String?
    
    /// Identifier for the bottom of the scroll content
    private let bottomID = "bottom"
    private let contentID = "content"

    public init(trackedValue: T, @ViewBuilder content: @escaping () -> Content) {
        self.trackedValue = trackedValue
        self.content = content
    }

    @available(macOS 14.0, *)
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    content()
                        .id(contentID)

                    // Bottom marker for scrolling
                    Rectangle()
                        .fill(.clear)
                        .frame(height: 1)
                        .id(bottomID)
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollID, anchor: .bottom)
            .defaultScrollAnchor(.bottom)
            .onChange(of: scrollID) { _, newScrollID in
                // When scrollID becomes nil, it means the view at the bottom edge has no ID.
                // This indicates the user has scrolled away from the bottom sentinel.
                // In this case, we disable auto-scrolling.
                if let newScrollID = newScrollID {
                    isAutoScrollEnabled = (newScrollID == bottomID)
                } else {
                    isAutoScrollEnabled = false
                }
            }
            .onChange(of: trackedValue) { _, _ in
                guard isAutoScrollEnabled else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onAppear {
                // Ensure we start at the bottom and enable auto-scroll
                isAutoScrollEnabled = true
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
} 
