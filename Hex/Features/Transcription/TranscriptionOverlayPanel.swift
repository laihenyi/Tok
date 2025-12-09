import AppKit
import SwiftUI
import Sauce
import Carbon
import ComposableArchitecture

// MARK: - Overlay Panel

/// A transparent floating panel that appears above the current input field
/// for editing transcribed text before insertion
final class TranscriptionOverlayPanel: NSPanel {

    // MARK: - Properties

    private var textField: HotkeyAwareTextField!
    private var containerView: NSVisualEffectView!
    private var globalEventMonitor: Any?
    private var isHotkeyPressed: Bool = false
    private var lastHotkeyEventTime: Date?  // Used to deduplicate notifications

    var onConfirm: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onTextChanged: ((String, String) -> Void)?  // (original, edited)
    var onHotkeyPressed: (() -> Void)?
    var onHotkeyReleased: (() -> Void)?

    private var originalText: String = ""

    // MARK: - Initialization

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        setupPanel()
        setupUI()
        setupKeyHandling()
        setupLocalEventMonitor()
    }

    deinit {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupPanel() {
        // Panel configuration for overlay behavior
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        // Allow the panel to become key without activating the app
        becomesKeyOnlyIfNeeded = true

        // Ignore mouse events outside the text field
        ignoresMouseEvents = false
    }

    private func setupUI() {
        // Container with subtle visual effect
        let panelBounds = NSRect(origin: .zero, size: frame.size)
        containerView = NSVisualEffectView(frame: panelBounds)
        containerView.material = .popover
        containerView.state = .active
        containerView.blendingMode = .behindWindow
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 8
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor.separatorColor.cgColor

        // Text field for editing - use custom subclass that can detect hotkeys
        textField = HotkeyAwareTextField(frame: NSRect(x: 8, y: 6, width: 384, height: 24))
        textField.isEditable = true
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.font = NSFont.systemFont(ofSize: 14)
        textField.focusRingType = .none
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.placeholderString = "語音辨識結果..."
        textField.delegate = self
        textField.hotkeyDelegate = self

        containerView.addSubview(textField)
        contentView = containerView
    }

    private func setupKeyHandling() {
        // Key handling is done through NSTextFieldDelegate
    }

    private func setupLocalEventMonitor() {
        debugLog("setupLocalEventMonitor: Setting up global event monitor")

        // Use global monitor to detect hotkeys when the panel doesn't receive keyboard events directly
        // (e.g., when using nonactivatingPanel style)
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isVisible else { return }

            // Get current hotkey from shared settings
            @Shared(.hexSettings) var hexSettings: HexSettings
            let hotkey = hexSettings.hotkey

            // Check if this event matches the hotkey
            let eventModifiers = Modifiers.from(carbonFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))

            // Handle key+modifier hotkeys
            if let hotkeyKey = hotkey.key {
                let eventKey = Sauce.shared.key(for: Int(event.keyCode))
                let matches = (eventKey == hotkeyKey && eventModifiers == hotkey.modifiers)

                if event.type == .keyDown && matches && !self.isHotkeyPressed {
                    self.isHotkeyPressed = true
                    self.debugLog("GlobalMonitor: HOTKEY PRESSED")
                    self.postHotkeyNotification(pressed: true)
                } else if event.type == .keyUp && self.isHotkeyPressed {
                    let releasedKey = Sauce.shared.key(for: Int(event.keyCode))
                    if releasedKey == hotkeyKey {
                        self.isHotkeyPressed = false
                        self.debugLog("GlobalMonitor: HOTKEY RELEASED")
                        self.postHotkeyNotification(pressed: false)
                    }
                }
            } else {
                // Handle modifier-only hotkeys
                if event.type == .flagsChanged {
                    if eventModifiers == hotkey.modifiers && !self.isHotkeyPressed {
                        self.isHotkeyPressed = true
                        self.debugLog("GlobalMonitor: MODIFIER HOTKEY PRESSED")
                        self.postHotkeyNotification(pressed: true)
                    } else if self.isHotkeyPressed && eventModifiers != hotkey.modifiers {
                        self.isHotkeyPressed = false
                        self.debugLog("GlobalMonitor: MODIFIER HOTKEY RELEASED")
                        self.postHotkeyNotification(pressed: false)
                    }
                }
            }
        }

        debugLog("setupLocalEventMonitor: Global monitor set up")
    }

    /// Post hotkey notification with deduplication
    private func postHotkeyNotification(pressed: Bool) {
        let now = Date()

        // Deduplicate: ignore if we just posted the same notification within 50ms
        if let lastTime = lastHotkeyEventTime, now.timeIntervalSince(lastTime) < 0.05 {
            debugLog("postHotkeyNotification: SKIPPED (dedupe) - pressed=\(pressed)")
            return
        }

        lastHotkeyEventTime = now

        if pressed {
            NotificationCenter.default.post(name: .overlayHotkeyPressed, object: nil)
        } else {
            NotificationCenter.default.post(name: .overlayHotkeyReleased, object: nil)
        }
        debugLog("postHotkeyNotification: POSTED - pressed=\(pressed)")
    }

    private func debugLog(_ message: String) {
        let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tok_overlay_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [Panel] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    // MARK: - Public Methods

    /// Show the overlay with transcribed text at the specified position
    func show(text: String, at position: NSPoint) {
        originalText = text
        textField.stringValue = text

        // Calculate position (slightly above the caret)
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        var adjustedPosition = position

        // Ensure the panel stays within screen bounds
        let panelWidth = frame.width
        let panelHeight = frame.height

        // Adjust X to keep panel on screen
        if adjustedPosition.x + panelWidth > screenFrame.maxX {
            adjustedPosition.x = screenFrame.maxX - panelWidth - 10
        }
        if adjustedPosition.x < screenFrame.minX {
            adjustedPosition.x = screenFrame.minX + 10
        }

        // Position above the caret with some offset
        adjustedPosition.y += 5

        // Ensure Y is within screen bounds
        if adjustedPosition.y + panelHeight > screenFrame.maxY {
            adjustedPosition.y = position.y - panelHeight - 25  // Show below instead
        }

        setFrameOrigin(adjustedPosition)

        // Show and focus
        orderFront(nil)
        makeKey()
        textField.selectText(nil)

        // Position cursor at end
        if let editor = textField.currentEditor() {
            editor.selectedRange = NSRange(location: text.count, length: 0)
        }

        // Debug: verify panel state
        debugLog("show() completed - isKeyWindow: \(isKeyWindow), isVisible: \(isVisible), canBecomeKey: \(canBecomeKey)")
    }

    /// Hide the overlay
    func hide() {
        // Resign key window status before hiding to return focus to previous app
        resignKey()
        orderOut(nil)

        // Activate the previous application to ensure hotkey monitoring works
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            frontApp.activate()
        }
    }

    /// Update the text (for streaming updates)
    func updateText(_ text: String) {
        let currentSelection = textField.currentEditor()?.selectedRange
        textField.stringValue = text
        originalText = text

        // Restore selection if possible
        if let selection = currentSelection, let editor = textField.currentEditor() {
            let newLocation = min(selection.location, text.count)
            editor.selectedRange = NSRange(location: newLocation, length: 0)
        }
    }

    /// Append text to existing content (for multiple recordings)
    func appendText(_ text: String) {
        let currentText = textField.stringValue
        let separator = currentText.isEmpty ? "" : " "
        let newText = currentText + separator + text
        textField.stringValue = newText
        originalText = newText

        // Position cursor at end
        if let editor = textField.currentEditor() {
            editor.selectedRange = NSRange(location: newText.count, length: 0)
        }
    }

    /// Get current text
    var currentText: String {
        textField.stringValue
    }

    /// Set streaming mode (show visual indicator)
    func setStreamingMode(_ isStreaming: Bool) {
        if isStreaming {
            textField.placeholderString = "辨識中..."
            containerView.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.5).cgColor
        } else {
            textField.placeholderString = "語音辨識結果..."
            containerView.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: - Key Handling

    override func sendEvent(_ event: NSEvent) {
        // Intercept keyboard events at the window level to detect hotkeys
        // This works even when the text field's field editor has focus
        if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged {
            debugLog("sendEvent: type=\(event.type.rawValue), keyCode=\(event.keyCode), isKeyWindow=\(isKeyWindow)")
            if handleHotkeyEvent(event) {
                return  // Consumed - don't pass to super
            }
        }
        super.sendEvent(event)
    }

    /// Handle hotkey detection - returns true if event was consumed
    private func handleHotkeyEvent(_ event: NSEvent) -> Bool {
        @Shared(.hexSettings) var hexSettings: HexSettings
        let hotkey = hexSettings.hotkey

        // Handle Enter and Escape specially
        if event.type == .keyDown {
            switch event.keyCode {
            case 36:  // Enter
                confirmText()
                return true
            case 53:  // Escape
                cancelEdit()
                return true
            default:
                break
            }
        }

        let eventModifiers = Modifiers.from(carbonFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))

        // Handle modifier-only hotkeys
        if hotkey.key == nil {
            if event.type == .flagsChanged {
                if eventModifiers == hotkey.modifiers && !isHotkeyPressed {
                    isHotkeyPressed = true
                    debugLog("Panel sendEvent: MODIFIER HOTKEY PRESSED")
                    postHotkeyNotification(pressed: true)
                    return true
                } else if isHotkeyPressed && eventModifiers != hotkey.modifiers {
                    isHotkeyPressed = false
                    debugLog("Panel sendEvent: MODIFIER HOTKEY RELEASED")
                    postHotkeyNotification(pressed: false)
                    return true
                }
            }
            return false
        }

        // Handle key+modifier hotkeys
        let eventKey = Sauce.shared.key(for: Int(event.keyCode))
        let matches = (eventKey == hotkey.key && eventModifiers == hotkey.modifiers)

        if event.type == .keyDown && matches && !isHotkeyPressed {
            isHotkeyPressed = true
            debugLog("Panel sendEvent: HOTKEY PRESSED - key=\(eventKey?.rawValue ?? "nil")")
            postHotkeyNotification(pressed: true)
            return true
        } else if event.type == .keyUp && isHotkeyPressed {
            let releasedKey = Sauce.shared.key(for: Int(event.keyCode))
            if releasedKey == hotkey.key {
                isHotkeyPressed = false
                debugLog("Panel sendEvent: HOTKEY RELEASED")
                postHotkeyNotification(pressed: false)
                return true
            }
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36:  // Enter
            confirmText()
        case 53:  // Escape
            cancelEdit()
        default:
            super.keyDown(with: event)
        }
    }

    private func confirmText() {
        let editedText = textField.stringValue

        debugLog("confirmText: originalText='\(originalText)', editedText='\(editedText)'")

        // Notify about text changes for learning
        if editedText != originalText {
            debugLog("confirmText: Text was modified! Calling onTextChanged")
            onTextChanged?(originalText, editedText)
        } else {
            debugLog("confirmText: No changes detected")
        }

        onConfirm?(editedText)
        hide()
    }

    private func cancelEdit() {
        onCancel?()
        hide()
    }

    // MARK: - Window Behavior

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - NSTextFieldDelegate

extension TranscriptionOverlayPanel: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            confirmText()
            return true
        } else if commandSelector == #selector(cancelOperation(_:)) {
            cancelEdit()
            return true
        }
        return false
    }
}

// MARK: - HotkeyAwareTextFieldDelegate

extension TranscriptionOverlayPanel: HotkeyAwareTextFieldDelegate {
    func hotkeyPressed() {
        debugLog("Panel: hotkeyPressed delegate callback - posting notification")
        NotificationCenter.default.post(name: .overlayHotkeyPressed, object: nil)
    }

    func hotkeyReleased() {
        debugLog("Panel: hotkeyReleased delegate callback - posting notification")
        NotificationCenter.default.post(name: .overlayHotkeyReleased, object: nil)
    }
}

// MARK: - Overlay Controller

/// Controller to manage the overlay panel lifecycle
final class TranscriptionOverlayController {

    static let shared = TranscriptionOverlayController()

    private var panel: TranscriptionOverlayPanel?
    private var correctionTracker: CorrectionTracker?

    // External callbacks (set by TCA through OverlayClient)
    private var externalOnConfirm: ((String) -> Void)?
    private var externalOnCancel: (() -> Void)?
    private var externalOnTextChanged: ((String, String) -> Void)?

    // Captured caret position (captured before recording starts)
    private var capturedCaretPosition: NSPoint?

    private init() {
        correctionTracker = CorrectionTracker()
    }

    // MARK: - Caret Position Capture

    /// Capture current caret position - call this BEFORE recording starts
    func captureCaretPosition() {
        capturedCaretPosition = getCaretPosition()
        if let pos = capturedCaretPosition {
            debugLog("Captured caret position: \(pos)")
        } else {
            debugLog("Failed to capture caret position - will use fallback")
        }
    }

    /// Debug logging to file
    private func debugLog(_ message: String) {
        let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tok_overlay_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    /// Clear captured position
    func clearCapturedPosition() {
        capturedCaretPosition = nil
    }

    // MARK: - Public Callback Setters

    func setOnConfirm(_ callback: @escaping (String) -> Void) {
        externalOnConfirm = callback
    }

    func setOnCancel(_ callback: @escaping () -> Void) {
        externalOnCancel = callback
    }

    func setOnTextChanged(_ callback: @escaping (String, String) -> Void) {
        externalOnTextChanged = callback
    }

    /// Show overlay with transcribed text
    func showOverlay(text: String, at position: NSPoint? = nil) {
        if panel == nil {
            panel = TranscriptionOverlayPanel()
            setupCallbacks()
        }

        // Priority: explicit position > captured position > live detection > center
        var positionSource = "unknown"
        let displayPosition: NSPoint

        if let pos = position {
            displayPosition = pos
            positionSource = "explicit"
        } else if let captured = capturedCaretPosition {
            displayPosition = captured
            positionSource = "captured"
        } else if let live = getCaretPosition() {
            displayPosition = live
            positionSource = "live"
        } else {
            displayPosition = getCenterPosition()
            positionSource = "center (fallback)"
        }

        debugLog("showOverlay - source: \(positionSource), position: \(displayPosition)")
        panel?.show(text: text, at: displayPosition)

        // Clear captured position after use
        capturedCaretPosition = nil
    }

    /// Update overlay text (for streaming)
    func updateOverlayText(_ text: String) {
        panel?.updateText(text)
    }

    /// Append text to overlay (for multiple recordings)
    func appendOverlayText(_ text: String) {
        debugLog("appendOverlayText called with text: \(text)")
        panel?.appendText(text)
    }

    /// Get current overlay text
    var currentOverlayText: String {
        panel?.currentText ?? ""
    }

    /// Set streaming mode
    func setStreamingMode(_ isStreaming: Bool) {
        panel?.setStreamingMode(isStreaming)
    }

    /// Hide overlay
    func hideOverlay() {
        panel?.hide()
    }

    /// Check if overlay is visible
    var isOverlayVisible: Bool {
        panel?.isVisible ?? false
    }

    private func setupCallbacks() {
        panel?.onConfirm = { [weak self] text in
            self?.handleConfirm(text: text)
        }

        panel?.onCancel = { [weak self] in
            self?.handleCancel()
        }

        panel?.onTextChanged = { [weak self] original, edited in
            self?.handleTextChanged(original: original, edited: edited)
        }
    }

    private func handleConfirm(text: String) {
        debugLog("handleConfirm called with text: \(text)")
        debugLog("externalOnConfirm is set: \(externalOnConfirm != nil)")
        // Call external callback if set (TCA handles paste)
        if let external = externalOnConfirm {
            debugLog("Calling external onConfirm callback")
            external(text)
            return
        }

        debugLog("No external callback, using fallback paste")
        // Fallback: Paste the text using pasteboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V to paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.simulatePaste()
        }
    }

    private func handleCancel() {
        debugLog("handleCancel called")
        debugLog("externalOnCancel is set: \(externalOnCancel != nil)")
        // Call external callback if set
        if let external = externalOnCancel {
            debugLog("Calling external onCancel callback")
            external()
            return
        }

        // Just hide, don't paste
        debugLog("No external callback, edit cancelled")
    }

    private func handleTextChanged(original: String, edited: String) {
        debugLog("handleTextChanged: original='\(original)', edited='\(edited)'")

        // Call external callback if set
        if let callback = externalOnTextChanged {
            debugLog("handleTextChanged: Calling externalOnTextChanged")
            callback(original, edited)
        } else {
            debugLog("handleTextChanged: No externalOnTextChanged callback set")
        }

        // Track corrections for learning
        correctionTracker?.trackCorrection(original: original, edited: edited)
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Get caret position using Accessibility API
    private func getCaretPosition() -> NSPoint? {
        // Check if we have accessibility permission
        let trusted = AXIsProcessTrusted()
        debugLog("getCaretPosition: AXIsProcessTrusted = \(trusted)")

        if !trusted {
            debugLog("getCaretPosition: No accessibility permission!")
            return nil
        }

        // Method A: Try system-wide focused element first
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        if result == .success, let element = focusedElement {
            debugLog("getCaretPosition: Got focused element from system-wide")
            if let position = extractPositionFromElement(element as! AXUIElement) {
                return position
            }
        } else {
            debugLog("getCaretPosition: System-wide focused element failed, error: \(result.rawValue)")
        }

        // Method B: Get focused app, then focused element from app
        var focusedApp: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        if appResult == .success, let app = focusedApp {
            debugLog("getCaretPosition: Got focused application")

            // Get focused window
            var focusedWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let window = focusedWindow {
                debugLog("getCaretPosition: Got focused window")

                // Try to get focused element from window
                var windowFocusedElement: CFTypeRef?
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &windowFocusedElement) == .success,
                   let winElem = windowFocusedElement {
                    debugLog("getCaretPosition: Got focused element from window")
                    if let position = extractPositionFromElement(winElem as! AXUIElement) {
                        return position
                    }
                }

                // Fallback: use window position
                if let position = getElementPosition(window as! AXUIElement) {
                    debugLog("getCaretPosition: Using window position as fallback")
                    return position
                }
            }

            // Try focused element directly from app
            var appFocusedElement: CFTypeRef?
            if AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &appFocusedElement) == .success,
               let appElem = appFocusedElement {
                debugLog("getCaretPosition: Got focused element from app")
                if let position = extractPositionFromElement(appElem as! AXUIElement) {
                    return position
                }
            }
        } else {
            debugLog("getCaretPosition: Failed to get focused app, error: \(appResult.rawValue)")
        }

        // Method C: Find the frontmost app (excluding Tok) and get its focused element
        if let position = getPositionFromFrontmostApp() {
            return position
        }

        debugLog("getCaretPosition: All methods failed")
        return nil
    }

    /// Get position from the frontmost application (excluding Tok itself)
    private func getPositionFromFrontmostApp() -> NSPoint? {
        let runningApps = NSWorkspace.shared.runningApplications
        let myBundleId = Bundle.main.bundleIdentifier ?? ""

        debugLog("getPositionFromFrontmostApp: Looking for frontmost app (excluding \(myBundleId))")

        // Get ordered list of apps by activation
        for app in runningApps where app.isActive && app.bundleIdentifier != myBundleId {
            debugLog("getPositionFromFrontmostApp: Found active app: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? ""))")

            let axApp = AXUIElementCreateApplication(app.processIdentifier)

            // Try to get focused element directly from the app first
            var appFocusedElement: CFTypeRef?
            let appFocusedResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &appFocusedElement)
            debugLog("getPositionFromFrontmostApp: App focused element result: \(appFocusedResult.rawValue)")

            if appFocusedResult == .success, let elem = appFocusedElement {
                debugLog("getPositionFromFrontmostApp: Got focused element from app")
                if let position = extractPositionFromElement(elem as! AXUIElement) {
                    return position
                }
            }

            // Get focused window
            var focusedWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let window = focusedWindow {
                debugLog("getPositionFromFrontmostApp: Got focused window")

                // Get focused element from window
                var windowFocusedElement: CFTypeRef?
                let windowFocusedResult = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &windowFocusedElement)
                debugLog("getPositionFromFrontmostApp: Window focused element result: \(windowFocusedResult.rawValue)")

                if windowFocusedResult == .success, let elem = windowFocusedElement {
                    debugLog("getPositionFromFrontmostApp: Got focused element from window")
                    if let position = extractPositionFromElement(elem as! AXUIElement) {
                        return position
                    }
                }

                // Try to find text area or text field in the window using different approach
                if let position = findTextInputPosition(in: window as! AXUIElement) {
                    return position
                }

                // Try using mouse cursor position (usually near the text input when typing)
                let mouseLocation = NSEvent.mouseLocation
                debugLog("getPositionFromFrontmostApp: Mouse location: \(mouseLocation)")

                // Check if mouse is within the window bounds
                if let windowPos = getElementPosition(window as! AXUIElement) {
                    var sizeValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
                       let szValue = sizeValue {
                        var size = CGSize.zero
                        AXValueGetValue(szValue as! AXValue, .cgSize, &size)

                        // Window bounds in screen coordinates
                        let windowRect = NSRect(origin: windowPos, size: size)
                        if windowRect.contains(mouseLocation) {
                            debugLog("getPositionFromFrontmostApp: Using mouse position (within window)")
                            return mouseLocation
                        }
                    }
                }

                // Use window position as fallback
                if let position = getElementPosition(window as! AXUIElement) {
                    debugLog("getPositionFromFrontmostApp: Using window position as final fallback")
                    return position
                }
            }
        }

        // Try recently active apps
        for app in runningApps where app.activationPolicy == .regular && app.bundleIdentifier != myBundleId {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)

            var focusedWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let window = focusedWindow {

                // Check if this window is on screen (has a valid position)
                var posValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &posValue) == .success {
                    debugLog("getPositionFromFrontmostApp: Found window from \(app.localizedName ?? "unknown")")

                    // Get focused element
                    var elem: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &elem) == .success,
                       let focusedElem = elem {
                        if let position = extractPositionFromElement(focusedElem as! AXUIElement) {
                            return position
                        }
                    }

                    // Use window position
                    if let position = getElementPosition(window as! AXUIElement) {
                        return position
                    }
                }
            }
        }

        debugLog("getPositionFromFrontmostApp: No suitable app found")
        return nil
    }

    /// Find text input position by traversing the element hierarchy
    private func findTextInputPosition(in element: AXUIElement) -> NSPoint? {
        // Get children of the element
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        for child in children {
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String else {
                continue
            }

            // Check if this is a text input element
            if role == "AXTextArea" || role == "AXTextField" || role == "AXWebArea" || role == "AXTextView" {
                debugLog("findTextInputPosition: Found text element with role: \(role)")

                // Check if it has focus
                var focusedValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXFocusedAttribute as CFString, &focusedValue) == .success,
                   let focused = focusedValue as? Bool, focused {
                    debugLog("findTextInputPosition: Element is focused")
                    if let position = extractPositionFromElement(child) {
                        return position
                    }
                }
            }

            // Recursively search in children (limit depth to avoid infinite loops)
            if let position = findTextInputPosition(in: child) {
                return position
            }
        }

        return nil
    }

    /// Extract position from an AX element using various methods
    private func extractPositionFromElement(_ element: AXUIElement) -> NSPoint? {
        // Log element role
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success {
            debugLog("extractPosition: Element role: \(roleValue as? String ?? "unknown")")
        }

        // Method 1: Try to get bounds for selected text range
        if let position = getPositionFromSelectedTextRange(element) {
            debugLog("extractPosition: Got position from selected text range: \(position)")
            return position
        }

        // Method 2: Try to get caret bounds directly
        if let position = getCaretBoundsPosition(element) {
            debugLog("extractPosition: Got position from caret bounds: \(position)")
            return position
        }

        // Method 3: Fallback to element position
        if let position = getElementPosition(element) {
            debugLog("extractPosition: Got position from element: \(position)")
            return position
        }

        return nil
    }

    /// Get position from selected text range
    private func getPositionFromSelectedTextRange(_ element: AXUIElement) -> NSPoint? {
        var selectedRangeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
              let rangeValue = selectedRangeValue else {
            return nil
        }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &bounds) == .success,
              let boundsValue = bounds else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else {
            return nil
        }

        // AX coordinates: origin at top-left of primary screen, Y increases downward
        // NSWindow coordinates: origin at bottom-left of primary screen, Y increases upward
        // We need to convert AX coordinates to NSWindow coordinates
        return convertAXPointToScreen(CGPoint(x: rect.origin.x, y: rect.origin.y + rect.height))
    }

    /// Try to get caret bounds directly
    private func getCaretBoundsPosition(_ element: AXUIElement) -> NSPoint? {
        // Some apps provide insertion point bounds
        var boundsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXInsertionPointBounds" as CFString, &boundsValue) == .success,
           let bounds = boundsValue {
            var rect = CGRect.zero
            if AXValueGetValue(bounds as! AXValue, .cgRect, &rect) {
                return convertAXPointToScreen(CGPoint(x: rect.origin.x, y: rect.origin.y + rect.height))
            }
        }
        return nil
    }

    /// Get element position as fallback
    private func getElementPosition(_ element: AXUIElement) -> NSPoint? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              let posValue = positionValue else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point) else {
            return nil
        }

        // Get size to position at bottom of element
        var elementHeight: CGFloat = 24  // Default height
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let szValue = sizeValue {
            var size = CGSize.zero
            if AXValueGetValue(szValue as! AXValue, .cgSize, &size) {
                elementHeight = size.height
            }
        }

        // Position at bottom-left of element
        return convertAXPointToScreen(CGPoint(x: point.x, y: point.y + elementHeight))
    }

    /// Convert AX coordinate (top-left origin) to NSWindow coordinate (bottom-left origin)
    private func convertAXPointToScreen(_ axPoint: CGPoint) -> NSPoint {
        // Get the primary screen height for coordinate conversion
        // AX uses top-left origin, NSWindow uses bottom-left origin
        guard let primaryScreen = NSScreen.screens.first else {
            return NSPoint(x: axPoint.x, y: axPoint.y)
        }

        // Primary screen's full height (not visible frame)
        let primaryScreenHeight = primaryScreen.frame.height

        // Convert Y: screenY = primaryScreenHeight - axY
        let screenY = primaryScreenHeight - axPoint.y

        return NSPoint(x: axPoint.x, y: screenY)
    }

    private func getCenterPosition() -> NSPoint {
        guard let screen = NSScreen.main else {
            return NSPoint(x: 100, y: 100)
        }

        let screenFrame = screen.visibleFrame
        return NSPoint(
            x: screenFrame.midX - 200,
            y: screenFrame.midY
        )
    }
}

// MARK: - Correction Tracker (Placeholder)

/// Tracks corrections made by the user for learning
class CorrectionTracker {

    func trackCorrection(original: String, edited: String) {
        guard original != edited else { return }

        print("[CorrectionTracker] Detected correction:")
        print("  Original: \(original)")
        print("  Edited: \(edited)")

        // Find word-level differences
        let diffs = findWordDifferences(original: original, edited: edited)
        for diff in diffs {
            print("  Diff: '\(diff.original)' → '\(diff.corrected)'")
        }

        // TODO: Save corrections and implement learning logic
    }

    private func findWordDifferences(original: String, edited: String) -> [(original: String, corrected: String)] {
        // Simple word-level diff (can be improved with proper diff algorithm)
        let originalWords = original.components(separatedBy: CharacterSet.whitespaces)
        let editedWords = edited.components(separatedBy: CharacterSet.whitespaces)

        var diffs: [(original: String, corrected: String)] = []

        // For now, just compare word by word
        let maxLen = max(originalWords.count, editedWords.count)
        for i in 0..<maxLen {
            let origWord = i < originalWords.count ? originalWords[i] : ""
            let editWord = i < editedWords.count ? editedWords[i] : ""

            if origWord != editWord && !origWord.isEmpty && !editWord.isEmpty {
                diffs.append((original: origWord, corrected: editWord))
            }
        }

        return diffs
    }
}

// MARK: - Hotkey Aware TextField

/// Protocol for hotkey detection in text field
protocol HotkeyAwareTextFieldDelegate: AnyObject {
    func hotkeyPressed()
    func hotkeyReleased()
}

/// Custom NSTextField that can detect hotkey presses even while editing
final class HotkeyAwareTextField: NSTextField {
    weak var hotkeyDelegate: HotkeyAwareTextFieldDelegate?
    private var isHotkeyActive = false

    override func keyDown(with event: NSEvent) {
        // Check if this is the hotkey
        if checkHotkey(event: event, isKeyDown: true) {
            return  // Consumed
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        // Check if hotkey was released
        if checkHotkey(event: event, isKeyDown: false) {
            return  // Consumed
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        // Handle modifier-only hotkeys
        @Shared(.hexSettings) var hexSettings: HexSettings
        let hotkey = hexSettings.hotkey

        if hotkey.key == nil {
            let eventModifiers = Modifiers.from(carbonFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))

            if eventModifiers == hotkey.modifiers && !isHotkeyActive {
                isHotkeyActive = true
                debugLog("HotkeyAwareTextField: MODIFIER HOTKEY PRESSED")
                hotkeyDelegate?.hotkeyPressed()
                return
            } else if isHotkeyActive && eventModifiers != hotkey.modifiers {
                isHotkeyActive = false
                debugLog("HotkeyAwareTextField: MODIFIER HOTKEY RELEASED")
                hotkeyDelegate?.hotkeyReleased()
                return
            }
        }

        super.flagsChanged(with: event)
    }

    private func checkHotkey(event: NSEvent, isKeyDown: Bool) -> Bool {
        @Shared(.hexSettings) var hexSettings: HexSettings
        let hotkey = hexSettings.hotkey

        // Only handle key+modifier hotkeys here (modifier-only handled in flagsChanged)
        guard hotkey.key != nil else { return false }

        let eventKey = Sauce.shared.key(for: Int(event.keyCode))
        let eventModifiers = Modifiers.from(carbonFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))

        let matches = (eventKey == hotkey.key && eventModifiers == hotkey.modifiers)

        if isKeyDown && matches && !isHotkeyActive {
            isHotkeyActive = true
            debugLog("HotkeyAwareTextField: HOTKEY PRESSED - key=\(eventKey?.rawValue ?? "nil")")
            hotkeyDelegate?.hotkeyPressed()
            return true
        } else if !isKeyDown && isHotkeyActive {
            let releasedKey = Sauce.shared.key(for: Int(event.keyCode))
            if releasedKey == hotkey.key {
                isHotkeyActive = false
                debugLog("HotkeyAwareTextField: HOTKEY RELEASED")
                hotkeyDelegate?.hotkeyReleased()
                return true
            }
        }

        return false
    }

    private func debugLog(_ message: String) {
        let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tok_overlay_debug.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }
}
