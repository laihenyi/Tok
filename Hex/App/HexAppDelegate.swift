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
