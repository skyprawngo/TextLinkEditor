import AppKit
import Sparkle

@main struct SparkleSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let bundle = Bundle.main
        precondition(bundle.bundleIdentifier == "com.textlinkeditor.update-smoke")
        defer { UserDefaults.standard.removePersistentDomain(forName: bundle.bundleIdentifier!) }
        precondition(bundle.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == false)
        precondition(bundle.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool == false)
        precondition(bundle.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool == false)
        precondition(bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        try controller.updater.start()
        precondition(controller.updater.automaticallyChecksForUpdates == false)
        precondition(controller.updater.automaticallyDownloadsUpdates == false)
        print("PASS: built bundle configuration and Sparkle runtime initialization")
    }
}
