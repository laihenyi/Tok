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

    /// The app that was active before the overlay was shown (target for paste)
    private var targetApp: NSRunningApplication?

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
        // Set to false so the panel can accept keyboard focus immediately when makeKey() is called
        becomesKeyOnlyIfNeeded = false

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
                    self.postHotkeyNotification(pressed: true)
                } else if event.type == .keyUp && self.isHotkeyPressed {
                    let releasedKey = Sauce.shared.key(for: Int(event.keyCode))
                    if releasedKey == hotkeyKey {
                        self.isHotkeyPressed = false
                        self.postHotkeyNotification(pressed: false)
                    }
                }
            } else {
                if event.type == .flagsChanged {
                    if eventModifiers == hotkey.modifiers && !self.isHotkeyPressed {
                        self.isHotkeyPressed = true
                        self.postHotkeyNotification(pressed: true)
                    } else if self.isHotkeyPressed && eventModifiers != hotkey.modifiers {
                        self.isHotkeyPressed = false
                        self.postHotkeyNotification(pressed: false)
                    }
                }
            }
        }
    }

    private func postHotkeyNotification(pressed: Bool) {
        let now = Date()
        // Deduplicate: ignore if we just posted the same notification within 50ms
        if let lastTime = lastHotkeyEventTime, now.timeIntervalSince(lastTime) < 0.05 {
            return
        }
        lastHotkeyEventTime = now
        if pressed {
            NotificationCenter.default.post(name: .overlayHotkeyPressed, object: nil)
        } else {
            NotificationCenter.default.post(name: .overlayHotkeyReleased, object: nil)
        }
    }


    // MARK: - Public Methods

    /// Show the overlay with transcribed text at the specified position
    func show(text: String, at position: NSPoint) {
        // Save the target app before showing overlay
        targetApp = NSWorkspace.shared.frontmostApplication

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

        // Restore panel properties that were changed during hide
        level = .floating
        alphaValue = 1.0

        makeKeyAndOrderFront(nil)
        makeFirstResponder(textField)

        // Select all text (this also ensures field editor is created)
        textField.selectText(nil)

        // Position cursor at end after a brief delay to ensure field editor is ready
        DispatchQueue.main.async { [weak self] in
            if let editor = self?.textField.currentEditor() {
                let textLength = self?.textField.stringValue.count ?? 0
                editor.selectedRange = NSRange(location: textLength, length: 0)
            }
        }
    }

    /// Hide the overlay
    func hide() {
        // Only do work if panel is actually visible (avoid double-hide issues)
        let wasVisible = isVisible || alphaValue > 0

        // Reset hotkey state
        isHotkeyPressed = false

        // Multi-step hide approach for reliable panel hiding:
        resignKey()
        setFrameOrigin(NSPoint(x: -10000, y: -10000))
        alphaValue = 0
        level = .normal
        orderOut(nil)

        // Only activate previous app if panel was actually visible
        // This prevents re-activation when hide() is called multiple times
        if wasVisible {
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                frontApp.activate()
            }
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
        if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged {
            if handleHotkeyEvent(event) {
                return
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
            case 36:  // Enter - check if IME is composing
                if let editor = textField.currentEditor() as? NSTextView,
                   editor.markedRange().length > 0 {
                    return false  // Let Enter pass to IME
                }
                confirmText()
                return true
            case 53:  // Escape - check if IME is composing
                if let editor = textField.currentEditor() as? NSTextView,
                   editor.markedRange().length > 0 {
                    return false  // Let Escape pass to IME
                }
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
                    postHotkeyNotification(pressed: true)
                    return true
                } else if isHotkeyPressed && eventModifiers != hotkey.modifiers {
                    isHotkeyPressed = false
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
            postHotkeyNotification(pressed: true)
            return true
        } else if event.type == .keyUp && isHotkeyPressed {
            if Sauce.shared.key(for: Int(event.keyCode)) == hotkey.key {
                isHotkeyPressed = false
                postHotkeyNotification(pressed: false)
                return true
            }
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
        // Check if IME is composing before handling Enter/Escape
        let isIMEComposing: Bool = {
            if let editor = textField.currentEditor() as? NSTextView {
                return editor.markedRange().length > 0
            }
            return false
        }()

        switch event.keyCode {
        case 36:  // Enter
            if isIMEComposing {
                super.keyDown(with: event)  // Let IME handle it
            } else {
                confirmText()
            }
        case 53:  // Escape
            if isIMEComposing {
                super.keyDown(with: event)  // Let IME handle it
            } else {
                cancelEdit()
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func confirmText() {
        let editedText = textField.stringValue
        let savedTargetApp = targetApp

        // Notify about text changes for learning
        if editedText != originalText {
            onTextChanged?(originalText, editedText)
        }

        // IMPORTANT: Hide the overlay FIRST, then activate target app, THEN paste
        // This ensures focus is properly returned before paste commands are sent
        hideForConfirm()

        // Activate the target app explicitly
        if let app = savedTargetApp {
            app.activate(options: [.activateIgnoringOtherApps])

            // Check if this is VS Code (needs longer delay for focus to settle)
            let bundleId = app.bundleIdentifier ?? ""
            let isVSCode = bundleId.contains("microsoft.VSCode")
            let delay = isVSCode ? 0.25 : 0.15  // 250ms for VS Code, 150ms for others

            // Wait for the app to become active before calling callback
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.onConfirm?(editedText)
            }
        } else {
            onConfirm?(editedText)
        }
    }

    /// Hide overlay without activating any app (used during confirm sequence)
    private func hideForConfirm() {
        // Simpler hide approach that preserves window focus behavior:
        // Just make it visually disappear, don't change level (which affects focus)
        resignKey()
        alphaValue = 0
        setFrameOrigin(NSPoint(x: -10000, y: -10000))
        orderOut(nil)
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
        NotificationCenter.default.post(name: .overlayHotkeyPressed, object: nil)
    }

    func hotkeyReleased() {
        NotificationCenter.default.post(name: .overlayHotkeyReleased, object: nil)
    }
}

// MARK: - Overlay Controller

/// Controller to manage the overlay panel lifecycle
final class TranscriptionOverlayController {

    static let shared = TranscriptionOverlayController()

    private var panel: TranscriptionOverlayPanel?

    // External callbacks (set by TCA through OverlayClient)
    private var externalOnConfirm: ((String) -> Void)?
    private var externalOnCancel: (() -> Void)?
    private var externalOnTextChanged: ((String, String) -> Void)?

    // Captured caret position (captured before recording starts)
    private var capturedCaretPosition: NSPoint?

    // Captured mouse position at hotkey press time (useful for terminals)
    private var capturedMousePosition: NSPoint?

    // Captured app info at hotkey press time
    private var capturedAppBundleId: String?

    // Last successful caret position (for better fallback)
    private var lastSuccessfulCaretPosition: NSPoint?
    private var lastSuccessfulCaretTime: Date?

    // App-specific handling cache
    private var appSpecificHandlers: [String: AppCaretHandler] = [:]

    private init() {
        setupAppSpecificHandlers()
    }

    /// Setup handlers for apps that need special treatment
    private func setupAppSpecificHandlers() {
        // VS Code and VS Code Insiders use Electron, need special handling
        appSpecificHandlers["com.microsoft.VSCode"] = .electronApp
        appSpecificHandlers["com.microsoft.VSCodeInsiders"] = .electronApp

        // Chrome-based apps - web content has poor AX support, use mouse position
        appSpecificHandlers["com.google.Chrome"] = .chromiumApp
        appSpecificHandlers["com.google.Chrome.canary"] = .chromiumApp
        appSpecificHandlers["com.brave.Browser"] = .chromiumApp
        appSpecificHandlers["com.microsoft.edgemac"] = .chromiumApp
        appSpecificHandlers["org.chromium.Chromium"] = .chromiumApp
        appSpecificHandlers["com.operasoftware.Opera"] = .chromiumApp
        appSpecificHandlers["com.vivaldi.Vivaldi"] = .chromiumApp
        appSpecificHandlers["company.thebrowser.Browser"] = .chromiumApp  // Arc

        // Safari and Firefox - try AX first, fallback to mouse
        appSpecificHandlers["com.apple.Safari"] = .browserApp
        appSpecificHandlers["com.apple.SafariTechnologyPreview"] = .browserApp
        appSpecificHandlers["org.mozilla.firefox"] = .browserApp
        appSpecificHandlers["org.mozilla.firefoxdeveloperedition"] = .browserApp

        // Terminal apps
        appSpecificHandlers["com.apple.Terminal"] = .terminalApp
        appSpecificHandlers["com.googlecode.iterm2"] = .terminalApp
        appSpecificHandlers["io.alacritty"] = .terminalApp
        appSpecificHandlers["com.github.wez.wezterm"] = .terminalApp
    }

    /// App-specific caret handling strategies
    enum AppCaretHandler {
        case standardApp      // Use standard AX methods
        case electronApp      // Electron apps: prefer mouse position + element bounds
        case chromiumApp      // Chrome/browsers: use mouse position (web content lacks AX support)
        case terminalApp      // Terminal: use window position
        case browserApp       // Safari/Firefox: similar to chromium but may have better AX
    }

    // MARK: - Caret Position Capture

    /// Capture current caret position - call this BEFORE recording starts
    func captureCaretPosition() {
        // Always capture mouse position and app info for fallback
        capturedMousePosition = NSEvent.mouseLocation
        capturedAppBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Try to get actual caret position
        capturedCaretPosition = getCaretPosition()
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
        }
        // Always setup callbacks to ensure they are connected
        // (externalOnConfirm may have been set before showOverlay is called)
        setupCallbacks()

        // Priority: explicit position > captured mouse > captured caret > live detection > center
        // Mouse position is most reliable as AX API often fails or returns wrong positions
        let displayPosition: NSPoint

        if let pos = position {
            displayPosition = pos
        } else if let mousePos = capturedMousePosition {
            // Use captured mouse position - most reliable across all apps
            displayPosition = mousePos
        } else if let captured = capturedCaretPosition {
            // Use AX-detected caret if available
            displayPosition = captured
        } else if let live = getCaretPosition() {
            displayPosition = live
        } else {
            displayPosition = getCenterPosition()
        }

        panel?.show(text: text, at: displayPosition)

        // Clear captured positions after use
        capturedCaretPosition = nil
        capturedMousePosition = nil
        capturedAppBundleId = nil
    }

    /// Update overlay text (for streaming)
    func updateOverlayText(_ text: String) {
        panel?.updateText(text)
    }

    /// Append text to overlay (for multiple recordings)
    func appendOverlayText(_ text: String) {
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
        // Call external callback if set (TCA handles paste)
        if let external = externalOnConfirm {
            external(text)
            return
        }

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
        // Call external callback if set
        if let external = externalOnCancel {
            external()
            return
        }
        // Just hide, don't paste
    }

    private func handleTextChanged(original: String, edited: String) {
        // Call external callback if set
        if let callback = externalOnTextChanged {
            callback(original, edited)
        }

        // Track corrections for learning
        CorrectionHistory.shared.recordCorrection(original: original, edited: edited)
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

    /// Get caret position using Accessibility API with app-specific handling
    private func getCaretPosition() -> NSPoint? {
        // Check if we have accessibility permission
        guard AXIsProcessTrusted() else {
            return nil
        }

        // Get frontmost app info for app-specific handling
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let bundleId = frontmostApp?.bundleIdentifier ?? ""
        let handler = appSpecificHandlers[bundleId] ?? .standardApp

        // For Electron apps, prioritize mouse position within focused window bounds
        if handler == .electronApp {
            if let position = getElectronAppCaretPosition(app: frontmostApp) {
                saveSuccessfulPosition(position)
                return position
            }
        }

        // For Chrome-based browsers, use mouse position (web content lacks proper AX)
        if handler == .chromiumApp {
            if let position = getBrowserCaretPosition(app: frontmostApp, tryAXFirst: false) {
                saveSuccessfulPosition(position)
                return position
            }
        }

        // For Safari/Firefox, try AX first then fallback to mouse
        if handler == .browserApp {
            if let position = getBrowserCaretPosition(app: frontmostApp, tryAXFirst: true) {
                saveSuccessfulPosition(position)
                return position
            }
        }

        // For terminal apps, use window-based positioning
        if handler == .terminalApp {
            if let position = getTerminalAppCaretPosition(app: frontmostApp) {
                saveSuccessfulPosition(position)
                return position
            }
        }

        // Method A: Try system-wide focused element first
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        if result == .success, let element = focusedElement {
            if let position = extractPositionFromElement(element as! AXUIElement) {
                saveSuccessfulPosition(position)
                return position
            }
        }

        // Method B: Get focused app, then focused element from app
        var focusedApp: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        if appResult == .success, let app = focusedApp {
            // Get focused window
            var focusedWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let window = focusedWindow {
                // Try to get focused element from window
                var windowFocusedElement: CFTypeRef?
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &windowFocusedElement) == .success,
                   let winElem = windowFocusedElement {
                    if let position = extractPositionFromElement(winElem as! AXUIElement) {
                        saveSuccessfulPosition(position)
                        return position
                    }
                }

                // Fallback: use window position
                if let position = getElementPosition(window as! AXUIElement) {
                    saveSuccessfulPosition(position)
                    return position
                }
            }

            // Try focused element directly from app
            var appFocusedElement: CFTypeRef?
            if AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &appFocusedElement) == .success,
               let appElem = appFocusedElement {
                if let position = extractPositionFromElement(appElem as! AXUIElement) {
                    saveSuccessfulPosition(position)
                    return position
                }
            }
        }

        // Method C: Find the frontmost app (excluding Tok) and get its focused element
        if let position = getPositionFromFrontmostApp() {
            saveSuccessfulPosition(position)
            return position
        }

        // Method D: Use last successful position if recent (within 30 seconds)
        if let lastPosition = lastSuccessfulCaretPosition,
           let lastTime = lastSuccessfulCaretTime,
           Date().timeIntervalSince(lastTime) < 30 {
            return lastPosition
        }

        return nil
    }

    /// Save a successful caret position for future fallback
    private func saveSuccessfulPosition(_ position: NSPoint) {
        lastSuccessfulCaretPosition = position
        lastSuccessfulCaretTime = Date()
    }

    /// Get caret position for Electron apps (VS Code, etc.)
    /// These apps often don't properly expose accessibility info
    private func getElectronAppCaretPosition(app: NSRunningApplication?) -> NSPoint? {
        guard let app = app else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Get focused window
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let window = focusedWindow else {
            return nil
        }

        // Get window position and size
        guard let windowPosition = getElementPosition(window as! AXUIElement) else {
            return nil
        }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let szValue = sizeValue else {
            return nil
        }

        var windowSize = CGSize.zero
        AXValueGetValue(szValue as! AXValue, .cgSize, &windowSize)

        // Use mouse position if it's within the window
        let mouseLocation = NSEvent.mouseLocation
        let windowRect = NSRect(origin: windowPosition, size: windowSize)

        if windowRect.contains(mouseLocation) {
            return mouseLocation
        }

        // Otherwise, position at a reasonable location in the window
        // Typically the editor area is in the center-right of VS Code
        return NSPoint(
            x: windowPosition.x + windowSize.width * 0.4,
            y: windowPosition.y + windowSize.height * 0.5
        )
    }

    /// Get caret position for terminal apps
    private func getTerminalAppCaretPosition(app: NSRunningApplication?) -> NSPoint? {
        guard let app = app else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Get focused window
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let window = focusedWindow else {
            return nil
        }

        // Try to get the focused element (might be the terminal text area)
        var focusedElement: CFTypeRef?
        if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
           let elem = focusedElement {
            if let position = extractPositionFromElement(elem as! AXUIElement) {
                return position
            }
        }

        // Fall back to window position
        return getElementPosition(window as! AXUIElement)
    }

    /// Get caret position for browser apps (Chrome, Safari, Firefox, etc.)
    /// Web content typically lacks proper accessibility support for cursor position
    /// so we use mouse position as the primary method
    private func getBrowserCaretPosition(app: NSRunningApplication?, tryAXFirst: Bool) -> NSPoint? {
        guard let app = app else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Get focused window
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let window = focusedWindow else {
            return nil
        }

        // Get window position and size for bounds checking
        guard let windowPosition = getElementPosition(window as! AXUIElement) else {
            return nil
        }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let szValue = sizeValue else {
            return nil
        }

        var windowSize = CGSize.zero
        AXValueGetValue(szValue as! AXValue, .cgSize, &windowSize)

        let windowRect = NSRect(origin: windowPosition, size: windowSize)

        // For Safari/Firefox, try AX methods first (they have better accessibility support)
        if tryAXFirst {
            // Try to find focused web area or text field
            var focusedElement: CFTypeRef?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
               let elem = focusedElement {

                // Check if this is a web area or text input
                var roleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(elem as! AXUIElement, kAXRoleAttribute as CFString, &roleValue) == .success,
                   let role = roleValue as? String {
                    // For text fields and text areas, try to get caret position
                    if role == "AXTextField" || role == "AXTextArea" || role == "AXWebArea" || role == "AXComboBox" {
                        if let position = extractPositionFromElement(elem as! AXUIElement) {
                            return position
                        }
                    }
                }

                // Try to get position from the focused element anyway
                if let position = extractPositionFromElement(elem as! AXUIElement) {
                    return position
                }
            }

            // Try searching deeper in the hierarchy for focused web content
            if let position = findWebContentInputPosition(in: window as! AXUIElement) {
                return position
            }
        }

        // Use mouse position if it's within the browser window
        let mouseLocation = NSEvent.mouseLocation

        if windowRect.contains(mouseLocation) {
            return mouseLocation
        }

        // Mouse is outside window - estimate position near the content area
        // Browsers typically have tab bar + address bar at top (~100px) and content below
        let estimatedContentY = windowPosition.y + windowSize.height - 150  // Below toolbar area
        return NSPoint(
            x: windowPosition.x + windowSize.width * 0.3,  // Roughly where content starts
            y: estimatedContentY
        )
    }

    /// Search for focused input elements in web content
    private func findWebContentInputPosition(in element: AXUIElement, depth: Int = 0) -> NSPoint? {
        // Limit recursion depth to avoid performance issues
        guard depth < 5 else { return nil }

        // Get children
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        for child in children {
            // Check role
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String else {
                continue
            }

            // Check if this is a web content area or text input
            if role == "AXWebArea" || role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
                // Check if focused
                var focusedValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXFocusedAttribute as CFString, &focusedValue) == .success,
                   let focused = focusedValue as? Bool, focused {
                    if let position = extractPositionFromElement(child) {
                        return position
                    }
                }

                // For web areas, search their children
                if role == "AXWebArea" {
                    if let position = findWebContentInputPosition(in: child, depth: depth + 1) {
                        return position
                    }
                }
            }

            // Continue searching in other elements
            if role == "AXGroup" || role == "AXScrollArea" || role == "AXSplitGroup" {
                if let position = findWebContentInputPosition(in: child, depth: depth + 1) {
                    return position
                }
            }
        }

        return nil
    }

    /// Get position from the frontmost application (excluding Tok itself)
    private func getPositionFromFrontmostApp() -> NSPoint? {
        let runningApps = NSWorkspace.shared.runningApplications
        let myBundleId = Bundle.main.bundleIdentifier ?? ""

        // Get ordered list of apps by activation
        for app in runningApps where app.isActive && app.bundleIdentifier != myBundleId {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)

            // Try to get focused element directly from the app first
            var appFocusedElement: CFTypeRef?
            let appFocusedResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &appFocusedElement)

            if appFocusedResult == .success, let elem = appFocusedElement {
                if let position = extractPositionFromElement(elem as! AXUIElement) {
                    return position
                }
            }

            // Get focused window
            var focusedWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let window = focusedWindow {
                // Get focused element from window
                var windowFocusedElement: CFTypeRef?
                let windowFocusedResult = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &windowFocusedElement)

                if windowFocusedResult == .success, let elem = windowFocusedElement {
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
                            return mouseLocation
                        }
                    }
                }

                // Use window position as fallback
                if let position = getElementPosition(window as! AXUIElement) {
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
                // Check if it has focus
                var focusedValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXFocusedAttribute as CFString, &focusedValue) == .success,
                   let focused = focusedValue as? Bool, focused {
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
        // Method 1: Try to get bounds for selected text range
        if let position = getPositionFromSelectedTextRange(element) {
            return position
        }

        // Method 2: Try to get caret bounds directly
        if let position = getCaretBoundsPosition(element) {
            return position
        }

        // Method 3: Fallback to element position
        return getElementPosition(element)
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
                hotkeyDelegate?.hotkeyPressed()
                return
            } else if isHotkeyActive && eventModifiers != hotkey.modifiers {
                isHotkeyActive = false
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
            hotkeyDelegate?.hotkeyPressed()
            return true
        } else if !isKeyDown && isHotkeyActive {
            let releasedKey = Sauce.shared.key(for: Int(event.keyCode))
            if releasedKey == hotkey.key {
                isHotkeyActive = false
                hotkeyDelegate?.hotkeyReleased()
                return true
            }
        }

        return false
    }
}
