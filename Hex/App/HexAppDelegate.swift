import ComposableArchitecture
import SwiftUI

class HexAppDelegate: NSObject, NSApplicationDelegate {
	var invisibleWindow: InvisibleWindow?
	var settingsWindow: NSWindow?
	var statusItem: NSStatusItem!

	@Dependency(\.soundEffects) var soundEffect
	@Dependency(\.recording) var recording
	@Shared(.hexSettings) var hexSettings: HexSettings

	func applicationDidFinishLaunching(_: Notification) {
		if isTesting {
			print("TESTING")
			return
		}

		// Reset model warm status to cold since models are unloaded when app closes
		$hexSettings.withLock { $0.transcriptionModelWarmStatus = .cold }

		Task {
			await soundEffect.preloadSounds()
		}

		// Initialize auto-learning manager to start listening for corrections
		_ = AutoLearningManager.shared

		print("HexAppDelegate did finish launching")

		// Set activation policy first
		updateAppMode()

		// Add notification observer
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleAppModeUpdate),
			name: NSNotification.Name("UpdateAppMode"),
			object: nil
		)

		// Add overlay notification observers
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleEditOverlayConfirmed(_:)),
			name: .editOverlayConfirmed,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleEditOverlayCancelled),
			name: .editOverlayCancelled,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleEditOverlayTextChanged(_:)),
			name: .editOverlayTextChanged,
			object: nil
		)
		// Add overlay hotkey notification observers
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleOverlayHotkeyPressed),
			name: .overlayHotkeyPressed,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleOverlayHotkeyReleased),
			name: .overlayHotkeyReleased,
			object: nil
		)

		// Send app launch action to check permissions and onboarding status
		HexApp.appStore.send(.appDidLaunch)

		// Then present main views
		presentMainView()

		// Only show settings window if not set to minimize to menu bar on launch
		// Also always show settings if onboarding hasn't been completed
		if !hexSettings.minimizeToMenuBarOnLaunch || !hexSettings.hasCompletedOnboarding {
			presentSettingsView()
			NSApp.activate(ignoringOtherApps: true)
		}
	}

	func presentMainView() {
		guard invisibleWindow == nil else {
			return
		}
		let transcriptionStore = HexApp.appStore.scope(state: \.transcription, action: \.transcription)
		let transcriptionView = TranscriptionView(store: transcriptionStore)
			// Removed extra top padding so status bar sticks to very top edge
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		invisibleWindow = InvisibleWindow.fromView(transcriptionView)
		invisibleWindow?.makeKeyAndOrderFront(nil)
	}

	func presentSettingsView() {
		if let settingsWindow = settingsWindow {
			settingsWindow.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let settingsView = AppView(store: HexApp.appStore)
		let settingsWindow = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 700, height: 700),
			styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable],
			backing: .buffered,
			defer: false
		)
		settingsWindow.titleVisibility = .visible
		settingsWindow.contentView = NSHostingView(rootView: settingsView)
		settingsWindow.makeKeyAndOrderFront(nil)
		settingsWindow.isReleasedWhenClosed = false
		settingsWindow.center()
        settingsWindow.toolbarStyle = NSWindow.ToolbarStyle.unified
		NSApp.activate(ignoringOtherApps: true)
		self.settingsWindow = settingsWindow
	}

	@objc private func handleAppModeUpdate() {
		Task {
			await updateAppMode()
		}
	}

	// MARK: - Edit Overlay Handlers

	@objc private func handleEditOverlayConfirmed(_ notification: Notification) {
		debugLog("[AppDelegate] handleEditOverlayConfirmed called")
		guard let text = notification.userInfo?["text"] as? String else {
			debugLog("[AppDelegate] handleEditOverlayConfirmed - no text in userInfo")
			return
		}
		debugLog("[AppDelegate] Sending editOverlayConfirmed action with text: \(text)")
		HexApp.appStore.send(.transcription(.editOverlayConfirmed(text)))
		debugLog("[AppDelegate] editOverlayConfirmed action sent")
	}

	@objc private func handleEditOverlayCancelled() {
		debugLog("[AppDelegate] handleEditOverlayCancelled called")
		HexApp.appStore.send(.transcription(.editOverlayCancelled))
		debugLog("[AppDelegate] editOverlayCancelled action sent")
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

	@objc private func handleEditOverlayTextChanged(_ notification: Notification) {
		guard let original = notification.userInfo?["original"] as? String,
			  let edited = notification.userInfo?["edited"] as? String else { return }
		HexApp.appStore.send(.transcription(.editOverlayTextChanged(original: original, edited: edited)))
	}

	@objc private func handleOverlayHotkeyPressed() {
		debugLog("[AppDelegate] handleOverlayHotkeyPressed called")
		HexApp.appStore.send(.transcription(.hotKeyPressed))
		debugLog("[AppDelegate] hotKeyPressed action sent from overlay")
	}

	@objc private func handleOverlayHotkeyReleased() {
		debugLog("[AppDelegate] handleOverlayHotkeyReleased called")
		HexApp.appStore.send(.transcription(.hotKeyReleased))
		debugLog("[AppDelegate] hotKeyReleased action sent from overlay")
	}

	@MainActor
	private func updateAppMode() {
		print("hexSettings.showDockIcon: \(hexSettings.showDockIcon)")
		if hexSettings.showDockIcon {
			NSApp.setActivationPolicy(.regular)
		} else {
			NSApp.setActivationPolicy(.accessory)
		}
	}

	func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
		presentSettingsView()
		return true
	}
}
