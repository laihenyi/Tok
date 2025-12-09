import Dependencies
import DependenciesMacros
import Foundation

// MARK: - Overlay Client

/// Client for managing the transcription edit overlay
@DependencyClient
struct OverlayClient: Sendable {
    /// Capture caret position - call BEFORE recording starts
    var captureCaretPosition: @Sendable () async -> Void

    /// Show the overlay with the given text
    var show: @Sendable (_ text: String) async -> Void

    /// Hide the overlay
    var hide: @Sendable () async -> Void

    /// Update the overlay text (for streaming)
    var updateText: @Sendable (_ text: String) async -> Void

    /// Append text to existing overlay content (for multiple recordings)
    var appendText: @Sendable (_ text: String) async -> Void

    /// Set streaming mode
    var setStreamingMode: @Sendable (_ isStreaming: Bool) async -> Void

    /// Check if overlay is visible
    var isVisible: @Sendable () async -> Bool = { false }

    /// Set callback for when user confirms text
    var setOnConfirm: @Sendable (@escaping (String) -> Void) async -> Void

    /// Set callback for when user cancels
    var setOnCancel: @Sendable (@escaping () -> Void) async -> Void

    /// Set callback for text changes (original, edited)
    var setOnTextChanged: @Sendable (@escaping (String, String) -> Void) async -> Void
}

// MARK: - Live Implementation

extension OverlayClient: DependencyKey {
    static let liveValue: OverlayClient = {
        let controller = TranscriptionOverlayController.shared

        return OverlayClient(
            captureCaretPosition: { @MainActor in
                controller.captureCaretPosition()
            },
            show: { @MainActor text in
                controller.showOverlay(text: text)
            },
            hide: { @MainActor in
                controller.hideOverlay()
            },
            updateText: { @MainActor text in
                controller.updateOverlayText(text)
            },
            appendText: { @MainActor text in
                controller.appendOverlayText(text)
            },
            setStreamingMode: { @MainActor isStreaming in
                controller.setStreamingMode(isStreaming)
            },
            isVisible: { @MainActor in
                controller.isOverlayVisible
            },
            setOnConfirm: { @MainActor callback in
                controller.setOnConfirm(callback)
            },
            setOnCancel: { @MainActor callback in
                controller.setOnCancel(callback)
            },
            setOnTextChanged: { @MainActor callback in
                controller.setOnTextChanged(callback)
            }
        )
    }()

    static let testValue = OverlayClient()
}

// MARK: - Dependency Values

extension DependencyValues {
    var overlayClient: OverlayClient {
        get { self[OverlayClient.self] }
        set { self[OverlayClient.self] = newValue }
    }
}
