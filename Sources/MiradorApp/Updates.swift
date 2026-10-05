import Foundation
import Observation
import Sparkle
import SwiftUI

/// Sparkle auto-updates. Only active in builds that carry an update feed (release builds); local builds without a
/// GitHub origin have none, and the UI says so instead of offering a check that cannot work.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    private let controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    private(set) var canCheck = false

    var isAvailable: Bool { controller != nil }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    private init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheck = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }
}

struct UpdatesCard: View {
    @State private var updates = Updates.shared
    @State private var automatic = Updates.shared.automaticallyChecks

    var body: some View {
        Card {
            CardHeader(title: "Updates", description: "Version \(updates.version)") {
                if updates.isAvailable {
                    Button("Check now") { updates.checkNow() }
                        .shadButton(.outline)
                        .disabled(!updates.canCheck)
                }
            }
            if updates.isAvailable {
                Toggle("Check for updates automatically", isOn: $automatic)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .onChange(of: automatic) { _, value in updates.automaticallyChecks = value }
                Muted(updates.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? "Not checked yet.", size: 11)
            } else {
                Muted("Local development build: auto-updates are off so a release never replaces your changes. Builds from the Releases page update themselves.", size: 11)
            }
        }
    }
}
