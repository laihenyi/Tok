import ComposableArchitecture
import Sparkle
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate
	@Environment(\.openWindow) private var openWindow

	var body: some Scene {
		MenuBarExtra {
			CheckForUpdatesView()

			// New: open Karaoke Live View
			Button("Live Transcript") {
				appDelegate.presentKaraokeView()
			}
			.keyboardShortcut("k", modifiers: [.option, .command])

			Button("Settings...") {
				appDelegate.presentSettingsView()
			}.keyboardShortcut(",")

			Divider()

			Button("Quit") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
		} label: {
			Label {
				// no title text
				EmptyView()
			} icon: {
				WithViewStore(HexApp.appStore, observe: { $0.transcription }) { viewStore in
					PacmanBarIcon(
						averagePower: viewStore.meter.averagePower,
						peakPower: viewStore.meter.peakPower,
						isRecording: viewStore.isRecording
					)
				}
			}
			.labelStyle(.iconOnly)
		}

		WindowGroup {}.defaultLaunchBehavior(.suppressed)
			.commands {
				CommandGroup(after: .appInfo) {
					CheckForUpdatesView()

					Button("Settings...") {
						appDelegate.presentSettingsView()
					}.keyboardShortcut(",")
				}
			}


	}
}
