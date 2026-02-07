//
//  PasteboardClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Sauce
import SwiftUI

@DependencyClient
struct PasteboardClient {
    var paste: @Sendable (String) async -> Void
    var copy: @Sendable (String) async -> Void
}

extension PasteboardClient: DependencyKey {
    static var liveValue: Self {
        let live = PasteboardClientLive()
        return .init(
            paste: { text in
                await live.paste(text: text)
            },
            copy: { text in
                await live.copy(text: text)
            }
        )
    }
}

extension DependencyValues {
    var pasteboard: PasteboardClient {
        get { self[PasteboardClient.self] }
        set { self[PasteboardClient.self] = newValue }
    }
}

struct PasteboardClientLive {
    @Shared(.hexSettings) var hexSettings: HexSettings

    @MainActor
    func paste(text: String) async {
        if hexSettings.useClipboardPaste {
            await pasteWithClipboard(text)
        } else {
            simulateTypingWithAppleScript(text)
        }
    }

    @MainActor
    func copy(text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // Stores the previous pasteboard owner change count
    private static var savedChangeCount: Int = 0
    // Stores the previous pasteboard contents name for tracking
    private static var savedPasteboardName: String?

    // More efficient approach that uses NSPasteboard's built-in functionality
    // Instead of copying all the data, we'll track the pasteboard state and create
    // a temporary pasteboard to hold the original data
    func savePasteboardState(pasteboard: NSPasteboard) -> NSPasteboard? {
        // If pasteboard is empty, nothing to save
        if pasteboard.pasteboardItems?.isEmpty ?? true {
            return nil
        }

        // Generate a unique name for the backup pasteboard
        let tempName = "xyz.2qs.Tok.backup.\(UUID().uuidString)"
        let backupPasteboard = NSPasteboard(name: .init(tempName))

        // Clear the backup pasteboard and write all contents from original
        backupPasteboard.clearContents()

        // Copy all items to the backup pasteboard by recreating them
        // We can't use writeObjects directly because NSPasteboardItem objects
        // are already associated with the original pasteboard
        if let items = pasteboard.pasteboardItems {
            var newItems: [NSPasteboardItem] = []

            for item in items {
                let newItem = NSPasteboardItem()

                // Copy all types and their data from the original item
                for type in item.types {
                    if let data = item.data(forType: type) {
                        newItem.setData(data, forType: type)
                    }
                }

                newItems.append(newItem)
            }

            // Write the new items to the backup pasteboard
            backupPasteboard.writeObjects(newItems)
        }

        // Save the current change count and name for later reference
        PasteboardClientLive.savedChangeCount = pasteboard.changeCount
        PasteboardClientLive.savedPasteboardName = tempName

        return backupPasteboard
    }

    // Restore the pasteboard state from a backup pasteboard
    func restorePasteboardFromBackup(mainPasteboard: NSPasteboard, backupPasteboard: NSPasteboard?) {
        // If no backup pasteboard, nothing to restore
        guard let backupPasteboard = backupPasteboard else { return }

        // Clear the main pasteboard
        mainPasteboard.clearContents()

        // Copy all items from backup to main pasteboard by recreating them
        // We can't use writeObjects directly because NSPasteboardItem objects
        // are already associated with the backup pasteboard
        if let items = backupPasteboard.pasteboardItems {
            var newItems: [NSPasteboardItem] = []

            for item in items {
                let newItem = NSPasteboardItem()

                // Copy all types and their data from the original item
                for type in item.types {
                    if let data = item.data(forType: type) {
                        newItem.setData(data, forType: type)
                    }
                }

                newItems.append(newItem)
            }

            // Write the new items to the main pasteboard
            mainPasteboard.writeObjects(newItems)
        }

        // Release the temporary pasteboard by clearing it
        backupPasteboard.clearContents()
    }

    // Legacy method to maintain compatibility - will be removed in future
    func restorePasteboardState(pasteboard: NSPasteboard, savedItems: [[String: Any]]) {
        // This is kept for compatibility but shouldn't be used anymore
        print("Warning: Using deprecated pasteboard restoration method")
    }

    /// Pastes current clipboard content to the frontmost application
    static func pasteToFrontmostApp() -> Bool {
        let script = """
        tell application "System Events"
            tell process (name of first application process whose frontmost is true)
                tell (menu item "Paste" of menu of menu item "Paste" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                    if exists then
                        log (get properties of it)
                        if enabled then
                            click it
                            return true
                        else
                            return false
                        end if
                    end if
                end tell
                tell (menu item "Paste" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                    if exists then
                        if enabled then
                            click it
                            return true
                        else
                            return false
                        end if
                    else
                        return false
                    end if
                end tell
            end tell
        end tell
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let result = scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("Error executing paste: \(error)")
                return false
            }
            return result.booleanValue
        }
        return false
    }

    /// Paste using AppleScript keystroke command (Cmd+V)
    /// This is more reliable for Electron/Chromium apps than CGEvent
    static func pasteWithAppleScriptKeystroke() -> Bool {
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("Error executing AppleScript keystroke: \(error)")
                return false
            }
            return true
        }
        return false
    }

    func pasteWithClipboard(_ text: String) async {
        // Wait a moment for the target app to be fully activated
        try? await Task.sleep(for: .milliseconds(50))

        let pasteboard = NSPasteboard.general

        // Save the original pasteboard only if we need to restore it
        let backupPasteboard = hexSettings.copyToClipboard ? nil : savePasteboardState(pasteboard: pasteboard)

        // Set our text in the clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Get frontmost app for debugging and determine paste strategy
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier ?? ""

        // Check if this is an Electron/Chromium app (AppleScript menu paste won't work)
        let isElectronOrChromium = bundleID.contains("microsoft.VSCode") ||
                                   bundleID.contains("Electron") ||
                                   bundleID.contains("com.google.Chrome") ||
                                   bundleID.contains("com.brave.Browser") ||
                                   bundleID.contains("com.microsoft.edgemac") ||
                                   bundleID.contains("Slack") ||
                                   bundleID.contains("Discord")

        // Check if this is specifically VS Code (needs special handling)
        let isVSCode = bundleID.contains("microsoft.VSCode")

        let source = CGEventSource(stateID: .combinedSessionState)
        var pasteSucceeded = false

        // For Electron/Chromium apps, skip AppleScript and go directly to CGEvent keypresses
        if isElectronOrChromium {
            print("[Pasteboard] Electron/Chromium app detected, using CGEvent keypresses directly")
        } else {
            // First try the AppleScript approach - it's more reliable in most native apps
            pasteSucceeded = PasteboardClientLive.pasteToFrontmostApp()
        }

        // If menu-based paste failed, try simulated keypresses
        if !pasteSucceeded {
            print("[Pasteboard] Using keystroke simulation for paste")

            // Add a delay to allow system to process and target app to be ready
            // Use longer delay for VS Code as it needs more time to regain focus
            let delayMs = isVSCode ? 200 : 100
            try? await Task.sleep(for: .milliseconds(delayMs))

            // For VS Code and other Electron apps, click at current mouse position first
            // to ensure the correct pane has keyboard focus, then use AppleScript keystroke
            if isVSCode {
                // Click at current mouse position to ensure focus
                let mouseLocation = NSEvent.mouseLocation

                // Convert to screen coordinates for CGEvent (flip Y axis)
                if let mainScreen = NSScreen.main {
                    let screenHeight = mainScreen.frame.height
                    let cgPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

                    // Post a mouse click at current position
                    if let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: cgPoint, mouseButton: .left) {
                        mouseDown.post(tap: .cgSessionEventTap)
                    }
                    usleep(20000) // 20ms
                    if let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: cgPoint, mouseButton: .left) {
                        mouseUp.post(tap: .cgSessionEventTap)
                    }
                }

                // Wait for click to be processed
                try? await Task.sleep(for: .milliseconds(100))

                // Now use AppleScript keystroke
                let keystrokeSucceeded = PasteboardClientLive.pasteWithAppleScriptKeystroke()
                pasteSucceeded = keystrokeSucceeded
            } else if isElectronOrChromium {
                // For other Electron/Chromium apps, use AppleScript keystroke which is more reliable
                // for apps with complex input handling (like xterm.js terminals)
                let keystrokeSucceeded = PasteboardClientLive.pasteWithAppleScriptKeystroke()
                pasteSucceeded = keystrokeSucceeded
            } else {
                // For other apps, use CGEvent
                let vKeyCode: CGKeyCode = await MainActor.run { Sauce.shared.keyCode(for: .v) }
                let cmdKeyCode: CGKeyCode = 55 // Command key

                // Create and post key events with proper timing
                autoreleasepool {
                    // Command down
                    if let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true) {
                        cmdDown.post(tap: .cgSessionEventTap)
                    }

                    usleep(10000) // 10ms

                    // V down with command flag
                    if let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) {
                        vDown.flags = .maskCommand
                        vDown.post(tap: .cgSessionEventTap)
                    }

                    usleep(10000) // 10ms

                    // V up with command flag
                    if let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) {
                        vUp.flags = .maskCommand
                        vUp.post(tap: .cgSessionEventTap)
                    }

                    usleep(10000) // 10ms

                    // Command up
                    if let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false) {
                        cmdUp.post(tap: .cgSessionEventTap)
                    }
                }

                pasteSucceeded = true
            }
        }

        // Only restore original pasteboard contents if:
        // 1. User doesn't want to keep text in clipboard AND
        // 2. The paste operation succeeded AND
        // 3. We have a backup pasteboard
        if !hexSettings.copyToClipboard && pasteSucceeded && backupPasteboard != nil {
            // Give paste operation time to complete
            try? await Task.sleep(for: .milliseconds(200))

            // Restore the original pasteboard state
            autoreleasepool {
                restorePasteboardFromBackup(mainPasteboard: pasteboard, backupPasteboard: backupPasteboard)
            }
        }

        // If we failed to paste AND user doesn't want clipboard retention,
        // log the issue but leave text in clipboard as fallback
        if !pasteSucceeded && !hexSettings.copyToClipboard {
            print("Paste operation failed. Text remains in clipboard as fallback.")
        }
    }

    func simulateTypingWithAppleScript(_ text: String) {
        let escapedText = text.replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "tell application \"System Events\" to keystroke \"\(escapedText)\"")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error = error {
            print("Error executing AppleScript: \(error)")
        }
    }

    enum PasteError: Error {
        case systemWideElementCreationFailed
        case focusedElementNotFound
        case elementDoesNotSupportTextEditing
        case failedToInsertText
    }

    static func insertTextAtCursor(_ text: String) throws {
        // Get the system-wide accessibility element
        let systemWideElement = AXUIElementCreateSystemWide()

        // Get the focused element
        var focusedElementRef: CFTypeRef?
        let axError = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)

        guard axError == .success, let focusedElementRef = focusedElementRef else {
            throw PasteError.focusedElementNotFound
        }

        let focusedElement = focusedElementRef as! AXUIElement

        // Verify if the focused element supports text insertion
        var value: CFTypeRef?
        let supportsText = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &value) == .success
        let supportsSelectedText = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &value) == .success

        if !supportsText && !supportsSelectedText {
            throw PasteError.elementDoesNotSupportTextEditing
        }

        // Insert text at cursor position by replacing selected text (or empty selection)
        let insertResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)

        if insertResult != .success {
            throw PasteError.failedToInsertText
        }
    }
}
