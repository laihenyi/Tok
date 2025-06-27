import Foundation
import AppKit
import Dependencies
import DependenciesMacros
import ScreenCaptureKit

/// A client that captures screenshots using ScreenCaptureKit.
/// Supports capturing the active window or the entire screen.
@DependencyClient
struct ScreenCaptureClient {
    /// Captures the active window and returns image data compressed under a caller-supplied limit.
    var captureActiveWindow: @Sendable () async throws -> Data
    
    /// Captures the primary screen and returns PNG encoded data.
    var captureScreen: @Sendable () async throws -> Data
    
    /// Captures a screenshot (prefers active window) under a caller-supplied size limit, expressed in bytes.
    var captureScreenshot: @Sendable (_ maxBytes: Int) async throws -> Data
}

extension ScreenCaptureClient: DependencyKey {
    static var liveValue: Self {
        let live = ScreenCaptureClientLive()
        return Self(
            captureActiveWindow: { try await live.captureActiveWindow() },
            captureScreen: { try await live.captureScreen() },
            captureScreenshot: { maxBytes in try await live.captureActiveWindow(maxBytes: maxBytes) }
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
    
    /// Captures the active window and returns image data compressed under a caller-supplied limit.
    /// If the active window cannot be captured, an error is thrown – **no** fallback to full-screen capture.
    func captureActiveWindow() async throws -> Data {
        return try await captureActiveWindow(maxBytes: 30 * 1024)
    }
    
    /// Captures the active window compressed to under `maxBytes`.
    func captureActiveWindow(maxBytes: Int) async throws -> Data {
        print("[ScreenCaptureClient] Attempting to capture active window…")
        if let rawCGImage = try? await captureActiveWindowCGImage() {
            let compressed = try compressCGImage(rawCGImage, maxBytes: maxBytes)
            print("[ScreenCaptureClient] Captured active window (\(compressed.count) bytes)")
            return compressed
        }
        print("[ScreenCaptureClient] Could not capture active window, falling back to screen capture")
        return try await captureScreen(maxBytes: maxBytes)
    }
    
    /// Captures the primary screen and returns PNG data
    func captureScreen() async throws -> Data {
        return try await captureScreen(maxBytes: 30 * 1024)
    }
    
    /// Captures the primary display compressed to under `maxBytes`.
    func captureScreen(maxBytes: Int) async throws -> Data {
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
            
            let data = try compressCGImage(screenshot, maxBytes: maxBytes)
            print("[ScreenCaptureClient] Captured screen (\(data.count) bytes)")
            return data
            
        } catch {
            print("[ScreenCaptureClient] Error capturing screen: \(error)")
            throw NSError(domain: "ScreenCaptureClient", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to capture screen: \(error.localizedDescription)"])
        }
    }
    
    /// Internal helper to produce an *uncompressed* CGImage of the active window.
    private func captureActiveWindowCGImage() async throws -> CGImage {
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
            
            // Create a content filter that captures ONLY this window (display-independent)
            // Using the `desktopIndependentWindow` initializer ensures the
            // resulting image contains just the window's content, without
            // the surrounding portions of the display.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            print("[ScreenCaptureClient] Created content filter, capturing image…")
            
            // Determine the display scale to capture at 1× logical resolution.
            let backingScale: CGFloat = {
                // Try to match the NSScreen that contains the window to get its scale factor
                let matchedScreen = NSScreen.screens.first { nsScreen in
                    nsScreen.frame.intersects(window.frame)
                }
                return matchedScreen?.backingScaleFactor ?? 1.0
            }()

            // Configure capture settings – pass point dimensions / scale so
            // ScreenCaptureKit produces a 1× (logical-point) image.
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width / backingScale)
            config.height = Int(window.frame.height / backingScale)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false // Usually don't want cursor in window captures
            
            // Capture the screenshot
            let screenshot = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            print("[ScreenCaptureClient] Screenshot for active window captured, converting to PNG…")
            
            return screenshot
            
        } catch {
            print("[ScreenCaptureClient] Error capturing active window: \(error)")
            throw error
        }
    }
    
    /// Resize-then-compress: progressively scales the image down (not below 400 px wide)
    /// and lowers JPEG quality until the encoded data fits within `maxBytes`.
    private func compressCGImage(_ cgImage: CGImage, maxBytes: Int, minWidth: Int = 400) throws -> Data {
        let qualities: [CGFloat] = [0.8, 0.6, 0.4, 0.25, 0.1]

        var currentImage = cgImage
        var targetWidth = cgImage.width

        func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
            let rep = NSBitmapImageRep(cgImage: image)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }

        func resize(cgImage: CGImage, toWidth: Int) -> CGImage? {
            let height = Int(Double(cgImage.height) * Double(toWidth) / Double(cgImage.width))
            guard let colorSpace = cgImage.colorSpace else { return nil }
            guard let ctx = CGContext(
                data: nil,
                width: toWidth,
                height: height,
                bitsPerComponent: cgImage.bitsPerComponent,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: cgImage.bitmapInfo.rawValue)
            else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: toWidth, height: height))
            return ctx.makeImage()
        }

        while true {
            for quality in qualities {
                if let data = encodeJPEG(currentImage, quality: quality) {
                    if data.count <= maxBytes {
                        return data
                    }
                    if targetWidth <= minWidth && quality == qualities.last {
                        // Return best-effort smallest image even if over limit.
                        return data
                    }
                }
            }

            // Reduce dimensions and try again.
            if targetWidth <= minWidth { break }
            targetWidth = max(minWidth, Int(Double(targetWidth) * 0.8))
            if let resized = resize(cgImage: currentImage, toWidth: targetWidth) {
                currentImage = resized
            } else {
                break
            }
        }

        // Fallback – lowest-quality encode
        guard let fallback = encodeJPEG(currentImage, quality: 0.1) else {
            throw NSError(domain: "ScreenCaptureClient", code: -7,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to compress image"])
        }
        return fallback
    }
} 
