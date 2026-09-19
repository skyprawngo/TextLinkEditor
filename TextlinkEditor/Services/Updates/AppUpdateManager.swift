import AppKit
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdateManager: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdateManager()
    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    private(set) var checking = false
    private(set) var statusKey = "updates.notChecked"
    private(set) var detail = ""
    private(set) var hasAppKey = false
    private(set) var updateSessionInProgress = false
    private var sessionObservation: NSKeyValueObservation?
    private var launched = false
    private var controller: SPUStandardUpdaterController?
    private var acceptedBuild: String?
    private let defaults: UserDefaults
    private let offerPresenter: ((PublishedUpdate) -> NSApplication.ModalResponse)?
    private let statusPresenter: ((String, String) -> Void)?
    private static let skippedBuildKey = "updates.skippedBuild"

    init(defaults: UserDefaults = .standard,
         offerPresenter: ((PublishedUpdate) -> NSApplication.ModalResponse)? = nil,
         statusPresenter: ((String, String) -> Void)? = nil) {
        self.defaults = defaults
        self.offerPresenter = offerPresenter
        self.statusPresenter = statusPresenter
        super.init()
        hasAppKey = defaults.bool(forKey: "updates.hasSavedAppKey")
        if !Self.isEnabled { statusKey = "updates.debugDisabled" }
    }

    var busy: Bool { checking || updateSessionInProgress }

    func start() {
        guard Self.isEnabled, !launched else { return }
        launched = true
        Task { await check(manual: false) }
    }

    func saveKey(_ value: String) async {
        guard Self.isEnabled, !busy, controller?.updater.sessionInProgress != true else { return }
        do {
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try UpdateIdentity.write(key, account: "app-key")
            hasAppKey = !key.isEmpty
            defaults.set(hasAppKey, forKey: "updates.hasSavedAppKey")
            statusKey = "updates.keySaved"
            detail = ""
        } catch {
            statusKey = "updates.failed"
            detail = error.localizedDescription
        }
    }

    func check(manual: Bool = true) async {
        guard Self.isEnabled, !busy, controller?.updater.sessionInProgress != true else { return }
        checking = true
        statusKey = "updates.checking"
        detail = ""
        defer { checking = false }
        do {
            // Public metadata first. This path must not access the Keychain or activate a device.
            let result = try await UpdateAPIClient().latest(version: currentVersion, build: currentBuild)
            guard result.update_available else {
                statusKey = "updates.current"
                if manual { showStatus() }
                return
            }
            guard let release = result.release else { throw URLError(.badServerResponse) }
            if !manual && defaults.string(forKey: Self.skippedBuildKey) == release.build {
                statusKey = "updates.skipped"
                detail = release.version
                return
            }
            statusKey = "updates.available"
            detail = release.version
            switch presentOffer(release) {
            case .alertFirstButtonReturn:
                try await authorizeAndOfferInstallation(release)
            case .alertSecondButtonReturn:
                defaults.set(release.build, forKey: Self.skippedBuildKey)
                statusKey = "updates.skipped"
            default:
                break
            }
        } catch {
            statusKey = "updates.failed"
            detail = error.localizedDescription
            if manual { showStatus() }
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
    private var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private func presentOffer(_ release: PublishedUpdate) -> NSApplication.ModalResponse {
        if let offerPresenter { return offerPresenter(release) }
        let alert = NSAlert()
        alert.messageText = L10n.get("updates.available")
        alert.informativeText = "\(currentVersion) → \(release.version)\n" + L10n.get("updates.releaseNotes")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isVerticallyResizable = true
        text.autoresizingMask = .width
        text.textContainer?.widthTracksTextView = true
        text.string = release.notes.isEmpty ? L10n.get("updates.noNotes") : release.notes
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: L10n.get("updates.install"))
        alert.addButton(withTitle: L10n.get("updates.skip"))
        alert.addButton(withTitle: L10n.get("updates.later"))
        return alert.runModal()
    }

    private func authorizeAndOfferInstallation(_ release: PublishedUpdate) async throws {
        // Consent has been obtained for this exact build; credentials are only read now.
        let result = try await UpdateAPIClient().check(
            deviceID: UpdateIdentity.deviceID(), appKey: UpdateIdentity.read("app-key") ?? "",
            version: currentVersion, build: currentBuild, targetBuild: release.build)
        guard result.license_status == "valid" else {
            let supported = ["unlicensed", "invalid", "revoked", "device_limit"]
            statusKey = supported.contains(result.license_status) ? "updates." + result.license_status : "updates.failed"
            showStatus()
            return
        }
        guard result.update_available else {
            statusKey = "updates.withdrawn"
            showStatus()
            return
        }
        guard let token = result.token, !token.isEmpty else { throw URLError(.badServerResponse) }
        acceptedBuild = release.build
        if controller == nil {
            let updater = SPUStandardUpdaterController(startingUpdater: false,
                updaterDelegate: self, userDriverDelegate: nil)
            try updater.updater.start()
            updater.updater.automaticallyChecksForUpdates = false
            updater.updater.automaticallyDownloadsUpdates = false
            updater.updater.sendsSystemProfile = false
            sessionObservation = updater.updater.observe(\.sessionInProgress, options: [.initial, .new]) { [weak self] updater, _ in
                let inProgress = updater.sessionInProgress
                Task { @MainActor [weak self] in self?.updateSessionInProgress = inProgress }
            }
            controller = updater
        }
        controller?.updater.httpHeaders = ["Authorization": "Bearer " + token]
        controller?.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        var components = URLComponents(url: UpdateAPIClient.origin.appendingPathComponent("v1/appcast.xml"), resolvingAgainstBaseURL: false)!
        if let acceptedBuild { components.queryItems = [URLQueryItem(name: "build", value: acceptedBuild)] }
        return components.url?.absoluteString
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip {
            defaults.set(updateItem.versionString, forKey: Self.skippedBuildKey)
            statusKey = "updates.skipped"
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle displays installation/check errors itself; keep Settings in sync too.
        let errorCode = (error as NSError).code
        if (error as NSError).domain == SUSparkleErrorDomain,
           errorCode == SUError.installationCanceledError.rawValue { return }
        statusKey = (error as NSError).domain == SUSparkleErrorDomain && errorCode == SUError.noUpdateError.rawValue
            ? "updates.noCompatible" : "updates.failed"
        detail = error.localizedDescription
    }

    private func showStatus() {
        if let statusPresenter {
            statusPresenter(statusKey, detail)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.get(statusKey)
        alert.informativeText = detail
        alert.addButton(withTitle: L10n.get("updates.ok"))
        alert.runModal()
    }

    // Sparkle can terminate without NSApplicationDelegate's normal termination path.
    // Ask the existing editor close/save flow before allowing update relaunch.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        let manager = EditorTabManager.shared
        guard manager.prepareToClose(manager.tabs) else { return false }
        if let path = ProjectManager.shared.currentProject?.path {
            manager.saveSession(to: path, omittingApprovedDiscards: true)
        }
        return true
    }
}
