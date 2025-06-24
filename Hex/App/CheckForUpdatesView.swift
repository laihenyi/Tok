import Combine
import ComposableArchitecture
import Sparkle
import SwiftUI

@objc
final class BuildNumberVersionComparator: NSObject, SUVersionComparison {
	func compareVersion(_ versionA: String, toVersion versionB: String) -> ComparisonResult {
		func extract(_ str: String) -> Int {
			// Keep only digit chunks and take the last numeric component as the build number
			let numbers = str.split { !$0.isNumber }.compactMap { Int($0) }
			return numbers.last ?? 0
		}
		let a = extract(versionA)
		let b = extract(versionB)
		if a == b { return .orderedSame }
		return a < b ? .orderedAscending : .orderedDescending
	}
}

final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
	private let comparator = BuildNumberVersionComparator()

	func versionComparator(for updater: SPUUpdater) -> SUVersionComparison? {
		comparator
	}

	func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
        self
    }
}

extension SparkleUpdaterDelegate: SPUStandardUserDriverDelegate, SUVersionDisplay {
    func formatUpdateVersion(
        fromUpdate update: SUAppcastItem,
        andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>,
        withBundleVersion bundleVersion: String
    ) -> String {
        // Replace CFBundleShortVersionString with CFBundleVersion, as the
        // latter shows build numbers.
        inOutBundleDisplayVersion.pointee = bundleVersion as NSString
        // This is already CFBundleVersion, as that's the only version in the
        // appcast.
        return update.displayVersionString
    }

	func formatBundleDisplayVersion(_ bundleDisplayVersion: String, withBundleVersion bundleVersion: String, matchingUpdate: SUAppcastItem?) -> String {
		return "(\(bundleVersion))"
	}
}

@Observable
@MainActor
final class CheckForUpdatesViewModel {
	// Single shared instance
	static let shared = CheckForUpdatesViewModel()

	// Keep the delegate alive for the lifetime of the view-model
	private let sparkleDelegate = SparkleUpdaterDelegate()

	// Stored updater instance configured with our custom delegate
	let controller: SPUStandardUpdaterController

	init() {
		// Initialize the updater first so it's available for the Combine publisher below
		self.controller = SPUStandardUpdaterController(
			startingUpdater: true,
			updaterDelegate: sparkleDelegate,
			userDriverDelegate: sparkleDelegate
		)

		// Observe when the user can manually check for updates so we can enable/disable the button
		anyCancellable = controller.updater.publisher(for: \.canCheckForUpdates)
			.sink { [weak self] in self?.canCheckForUpdates = $0 }
	}

	var anyCancellable: AnyCancellable?

	var canCheckForUpdates = false

	func checkForUpdates() {
		controller.updater.checkForUpdates()
	}
}

struct CheckForUpdatesView: View {
	@State var viewModel = CheckForUpdatesViewModel.shared

	var body: some View {
		Button("Check for Updates…", action: viewModel.checkForUpdates)
			.disabled(!viewModel.canCheckForUpdates)
	}
}
