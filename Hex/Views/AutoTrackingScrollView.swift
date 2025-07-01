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
    /// Bound to the `ScrollView` via the `scrollPosition(id:)` modifier.
    /// When we want to stick to the bottom we assign this property the
    /// identifier of the bottom sentinel view.
    @State private var scrollTargetID: UUID?

    /// Identifier for the invisible sentinel placed at the bottom of the
    /// scroll content. When this view is visible, we consider ourselves "at
    /// bottom".
    private let bottomSentinelID = UUID()

    public init(trackedValue: T, @ViewBuilder content: @escaping () -> Content) {
        self.trackedValue = trackedValue
        self.content = content
    }

    @available(macOS 14.0, *)
    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                content()

                // Invisible sentinel used to (re-)enable auto-scrolling when
                // it becomes visible.
                Color.clear
                    .frame(height: 1)
                    .id(bottomSentinelID)
                    .onAppear { isAutoScrollEnabled = true }
                    .onDisappear { isAutoScrollEnabled = false }
            }
            // Required so the sentinel (and any other child) can be targeted
            // by the `ScrollPosition` APIs.
            .scrollTargetLayout()
        }
        // Bind the new scrolling API.
        .scrollPosition(id: $scrollTargetID)
        .onChange(of: trackedValue) { _, _ in
            guard isAutoScrollEnabled else { return }
            withAnimation {
                withTransaction(\.scrollTargetAnchor, .bottom) {
                    scrollTargetID = bottomSentinelID
                }
            }
        }
        .onAppear {
            // Ensure we start at the bottom.
            withTransaction(\.scrollTargetAnchor, .bottom) {
                scrollTargetID = bottomSentinelID
            }
        }
    }
} 