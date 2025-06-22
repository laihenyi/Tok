import Foundation
import AppKit
import Dependencies
import DependenciesMacros
import ScreenCaptureKit

/// A client that captures screenshots using ScreenCaptureKit.
/// Supports capturing the active window or the entire screen.
@DependencyClient
struct ScreenCaptureClient {
    /// Captures the active window and returns PNG encoded data.
    /// Falls back to screen capture if no active window is available.
    var captureActiveWindow: @Sendable () async throws -> Data
    
    /// Captures the primary screen and returns PNG encoded data.
    var captureScreen: @Sendable () async throws -> Data
    
    /// Captures the active window and returns PNG encoded data.
    /// This is the main method that should be used for most use cases.
    var captureScreenshot: @Sendable () async throws -> Data
}

extension ScreenCaptureClient: DependencyKey {
    static var liveValue: Self {
        let live = ScreenCaptureClientLive()
        return Self(
            captureActiveWindow: { try await live.captureActiveWindow() },
            captureScreen: { try await live.captureScreen() },
            captureScreenshot: { try await live.captureActiveWindow() } // Default to active window
        )
    }
}

extension DependencyValues {
    var screenCapture: ScreenCaptureClient {
        get { self[ScreenCaptureClient.self] }
        set { self[ScreenCaptureClient.self] = newValue }
    }
}

/// Live implementation of ScreenCaptureClient using ScreenCaptureKit
class ScreenCaptureClientLive {
    
    /// Captures the active window and returns PNG data
    func captureActiveWindow() async throws -> Data {
        print("[ScreenCaptureClient] Attempting to capture active window…")
        // First, try to get the active window
        if let activeWindowData = try? await captureActiveWindowInternal() {
            print("[ScreenCaptureClient] Captured active window (\(activeWindowData.count) bytes)")
            return activeWindowData
        }
        
        // Fallback to screen capture if we can't get the active window
        print("[ScreenCaptureClient] Could not capture active window, falling back to screen capture")
        return try await captureScreen()
    }
    
    /// Captures the entire screen and returns PNG data
    func captureScreen() async throws -> Data {
        print("[ScreenCaptureClient] Capturing entire screen…")
        do {
            // Get all available content
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            
            // Get the main display
            guard let mainDisplay = content.displays.first else {
                throw NSError(domain: "ScreenCaptureClient", code: -4,
                             userInfo: [NSLocalizedDescriptionKey: "No displays available"])
            }
            
            // Create content filter for the entire display
            let filter = SCContentFilter(display: mainDisplay, excludingWindows: [])
            
            // Configure capture settings
            let config = SCStreamConfiguration()
            config.width = Int(mainDisplay.frame.width)
            config.height = Int(mainDisplay.frame.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            
            // Capture the screenshot
            let screenshot = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            
            let data = try convertCGImageToPNG(screenshot)
            print("[ScreenCaptureClient] Captured screen (\(data.count) bytes)")
            return data
            
        } catch {
            print("[ScreenCaptureClient] Error capturing screen: \(error)")
            throw NSError(domain: "ScreenCaptureClient", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to capture screen: \(error.localizedDescription)"])
        }
    }
    
    /// Internal method to capture the active window
    private func captureActiveWindowInternal() async throws -> Data {
        print("[ScreenCaptureClient] captureActiveWindowInternal: fetching shareable content…")
        do {
            // Get all available content
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            print("[ScreenCaptureClient] captureActiveWindowInternal: obtained \(content.windows.count) windows, \(content.displays.count) displays")
            
            // Find the active window using NSWorkspace
            let activeApp = NSWorkspace.shared.frontmostApplication
            print("[ScreenCaptureClient] Active app bundle id: \(activeApp?.bundleIdentifier ?? "unknown")")
            
            // Find the window belonging to the active application
            let activeWindow = content.windows.first { window in
                window.owningApplication?.bundleIdentifier == activeApp?.bundleIdentifier &&
                window.isOnScreen &&
                window.frame.width > 100 && // Ignore very small windows
                window.frame.height > 100
            }
            print("[ScreenCaptureClient] Active window found: \(activeWindow != nil)")
            
            guard let window = activeWindow else {
                throw NSError(domain: "ScreenCaptureClient", code: -5,
                             userInfo: [NSLocalizedDescriptionKey: "No active window found"])
            }
            
            // Get the display that contains this window
            let windowDisplay = content.displays.first { display in
                display.frame.intersects(window.frame)
            } ?? content.displays.first
            print("[ScreenCaptureClient] Found display for window: \(windowDisplay != nil)")
            
            guard let display = windowDisplay else {
                throw NSError(domain: "ScreenCaptureClient", code: -6,
                             userInfo: [NSLocalizedDescriptionKey: "No display found for window"])
            }
            
            // Create content filter for just this window
            let filter = SCContentFilter(display: display, including: [window])
            print("[ScreenCaptureClient] Created content filter, capturing image…")
            
            // Configure capture settings
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false // Usually don't want cursor in window captures
            
            // Capture the screenshot
            let screenshot = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            print("[ScreenCaptureClient] Screenshot for active window captured, converting to PNG…")
            
            let data = try convertCGImageToPNG(screenshot)
            print("[ScreenCaptureClient] Active window PNG size: \(data.count) bytes")
            return data
            
        } catch {
            print("[ScreenCaptureClient] Error capturing active window: \(error)")
            throw error
        }
    }
    
    /// Converts a CGImage to PNG data
    private func convertCGImageToPNG(_ cgImage: CGImage) throws -> Data {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ScreenCaptureClient", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG data"])
        }
        return pngData
    }
} 