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

    // Function to save the current state of the NSPasteboard
    func savePasteboardState(pasteboard: NSPasteboard) -> [[String: Any]] {
        var savedItems: [[String: Any]] = []
        
        // Limit how many pasteboard items we save to avoid excessive memory use
        let itemsToSave = pasteboard.pasteboardItems?.prefix(5) ?? []
        
        for item in itemsToSave {
            var itemDict: [String: Any] = [:]
            // Prioritize string content which is typically smaller
            if item.types.contains(.string), let string = item.string(forType: .string) {
                itemDict[NSPasteboard.PasteboardType.string.rawValue] = string.data(using: .utf8)
                savedItems.append(itemDict)
                continue
            }
            
            // For non-string content, limit the types we save
            let typesToSave = item.types.prefix(2) // Only save up to 2 types per item
            for type in typesToSave {
                if let data = item.data(forType: type) {
                    // Only save data up to 1MB to prevent large memory usage
                    if data.count <= 1024 * 1024 {
                        itemDict[type.rawValue] = data
                    }
                }
            }
            if !itemDict.isEmpty {
                savedItems.append(itemDict)
            }
        }
        
        return savedItems
    }

    // Function to restore the saved state of the NSPasteboard
    func restorePasteboardState(pasteboard: NSPasteboard, savedItems: [[String: Any]]) {
        pasteboard.clearContents()
        
        for itemDict in savedItems {
            let item = NSPasteboardItem()
            for (type, data) in itemDict {
                if let data = data as? Data {
                    item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
                }
            }
            pasteboard.writeObjects([item])
        }
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

    func pasteWithClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        
        // Only save pasteboard state if we need to restore it later
        let originalItems = hexSettings.copyToClipboard ? [] : savePasteboardState(pasteboard: pasteboard)
        
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        
        // First try the AppleScript approach - it's more reliable in most apps
        var pasteSucceeded = PasteboardClientLive.pasteToFrontmostApp()
        
        // If menu-based paste failed, try simulated keypresses
        if !pasteSucceeded {
            print("Failed to paste to frontmost app, falling back to simulated keypresses")
            
            // Add a small delay to allow system to process
            try? await Task.sleep(for: .milliseconds(100))
            
            let vKeyCode = Sauce.shared.keyCode(for: .v)
            let cmdKeyCode: CGKeyCode = 55 // Command key

            // Create cmd down event
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true)

            // Create v down event
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
            vDown?.flags = .maskCommand

            // Create v up event
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
            vUp?.flags = .maskCommand

            // Create cmd up event
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)

            // Post the events with small delays between them
            cmdDown?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(10))
            vDown?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(10))
            vUp?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(10))
            cmdUp?.post(tap: .cghidEventTap)
            
            // Assume keypress-based paste succeeded - text will remain in clipboard as fallback
            pasteSucceeded = true
        }
        
        // Only restore original pasteboard contents if:
        // 1. Copying to clipboard is disabled AND
        // 2. The paste operation succeeded AND
        // 3. We have original items to restore
        if !hexSettings.copyToClipboard && pasteSucceeded && !originalItems.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))  // Give paste operation time to complete
            
            // Use autoreleasepool to help manage memory during pasteboard operations
            autoreleasepool {
                pasteboard.clearContents()
                restorePasteboardState(pasteboard: pasteboard, savedItems: originalItems)
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
        
        // // Get any selected text
        // var selectedText: String = ""
        // if AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &value) == .success,
        //    let selectedValue = value as? String {
        //     selectedText = selectedValue
        // }
        
        // print("selected text: \(selectedText)")
        
        // Insert text at cursor position by replacing selected text (or empty selection)
        let insertResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        
        if insertResult != .success {
            throw PasteError.failedToInsertText
        }
    }
}
