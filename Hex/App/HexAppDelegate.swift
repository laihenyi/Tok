import ComposableArchitecture
import SwiftUI
import AppKit

class HexAppDelegate: NSObject, NSApplicationDelegate {
	var invisibleWindow: InvisibleWindow?
	var settingsWindow: NSWindow?
	var karaokeWindow: NSWindow?
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

		// After reset model warm status, migrate legacy model folder
		performLegacyModelSymlinkMigration()

		Task {
			await soundEffect.preloadSounds()
		}
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

		// Then present main views
		presentMainView()
		presentSettingsView()
		NSApp.activate(ignoringOtherApps: true)
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

	func presentKaraokeView() {
		if let karaokeWindow = karaokeWindow {
			karaokeWindow.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let karaokeWindow = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 800, height: 600),
			styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		karaokeWindow.title = "Live Transcript"
		karaokeWindow.titleVisibility = .hidden
		karaokeWindow.titlebarAppearsTransparent = true
		if #available(macOS 11.0, *) {
			karaokeWindow.titlebarSeparatorStyle = .none
		}

		// Allow translucency and any transparent areas in our SwiftUI view to show
		// whatever is behind the window.
		karaokeWindow.isOpaque = false
		karaokeWindow.backgroundColor = .clear

		// By default, the karaoke window should float above normal windows (like original code)
		karaokeWindow.level = .floating

		// Set the karaokeWindow property BEFORE creating the view so onAppear can access it
		self.karaokeWindow = karaokeWindow

		let karaokeView = KaraokeView(
			store: Store(initialState: KaraokeFeature.State()) {
				KaraokeFeature()
			},
			appDelegate: self
		)
		karaokeWindow.contentView = NSHostingView(rootView: karaokeView)

		karaokeWindow.makeKeyAndOrderFront(nil)
		karaokeWindow.isReleasedWhenClosed = false
		karaokeWindow.setFrameAutosaveName("KaraokeWindowFrame")
		NSApp.activate(ignoringOtherApps: true)
	}

	func setKaraokeWindowLevel(_ level: NSWindow.Level) {
		guard let window = karaokeWindow else { return }

		// Promote the window to the requested higher level when "pinned" so that it
		// stays above standard windows from *any* application (not just our own).
		// `.statusBar` is one step above `.modalPanel` and should guarantee that the
		// window remains visible even when other apps create floating panels.
		window.level = level

		// Force window reordering based on the new level
		if level == .normal {
			// For normal level, send window to back to ensure it can be covered
			window.orderBack(nil)
		} else {
			// For higher levels, bring to front
			window.makeKeyAndOrderFront(nil)
		}

		if level == .normal {
			// Default normal window behavior when unpinned
			window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])

			if let panel = window as? NSPanel {
				panel.hidesOnDeactivate = true
			}
		} else {
			// Ensure the window stays visible when our app loses focus and appears in all
			// Spaces and full-screen apps.
			window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])

			if let panel = window as? NSPanel {
				panel.hidesOnDeactivate = false
			}
		}

		// Bring the window to the front so the new level takes effect immediately.
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
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

	/// Creates symbolic links from the legacy application support folder (com.kitlangton.Hex)
	/// into the current folder (xyz.2qs.Tok) so that previously downloaded models remain
	/// accessible after the bundle identifier change. This runs at launch and only creates
	/// links for items that are missing in the new location.
	private func performLegacyModelSymlinkMigration() {
		let fm = FileManager.default
		
		do {
			// Locate the user's Application Support directory
			let appSupportURL = try fm.url(for: .applicationSupportDirectory,
			                             in: .userDomainMask,
			                             appropriateFor: nil,
			                             create: false)
			// Old: <Application Support>/com.kitlangton.Hex/models/argmaxinc/whisperkit-coreml/
			let oldBase = appSupportURL
				.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
				.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
			// New: <Application Support>/xyz.2qs.Tok/models/argmaxinc/whisperkit-coreml/
			let newBase = appSupportURL
				.appendingPathComponent("xyz.2qs.Tok", isDirectory: true)
				.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
			
			// Nothing to migrate if the legacy path doesn't exist
			guard fm.fileExists(atPath: oldBase.path) else { return }
			
			// Ensure the destination base directory exists
			try fm.createDirectory(at: newBase, withIntermediateDirectories: true)
			
			// Enumerate all immediate children in the legacy folder (model variants)
			let legacyContents = try fm.contentsOfDirectory(at: oldBase,
			                                            includingPropertiesForKeys: nil,
			                                            options: [.skipsHiddenFiles])
			for oldItem in legacyContents {
				let destination = newBase.appendingPathComponent(oldItem.lastPathComponent, isDirectory: true)
				// Create a symlink only if the destination does not already exist
				if !fm.fileExists(atPath: destination.path) {
					do {
						try fm.createSymbolicLink(at: destination, withDestinationURL: oldItem)
						print("Created symlink: \(destination.path) → \(oldItem.path)")
					} catch {
						print("Failed to create symlink for \(oldItem.lastPathComponent): \(error)")
					}
				}
			}
		} catch {
			print("Model folder migration error: \(error)")
		}
	}
}
