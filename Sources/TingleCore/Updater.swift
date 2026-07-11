import AppKit
import Sparkle
import os

/// Sparkle auto-updates. Only meaningful in the bundled .app (the feed URL
/// and EdDSA public key live in Info.plist); running as a bare dev binary
/// this stays inert. Updates flow: auto-release publishes a zip + signed
/// appcast entry to the gh-pages appcast; running apps check daily and
/// prompt to install. Requires the repo to be public to actually fetch.
final class Updater {
    private var controller: SPUStandardUpdaterController?
    private let log = Logger(subsystem: Log.subsystem, category: "updater")

    /// True when running from a real bundle with a feed configured.
    var isActive: Bool { controller != nil }

    init() {
        guard Bundle.main.bundleIdentifier == "com.tutorintelligence.tingle",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            log.info("updater inert (dev binary or no feed configured)")
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        log.info("Sparkle updater active")
    }

    @objc func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
