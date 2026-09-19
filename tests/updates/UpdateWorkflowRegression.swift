import AppKit
import Foundation

struct PublishedUpdate {
    let build: String
    let version: String
    let notes: String
    let minimum_os: String
}
struct ReleaseCheckResponse { let update_available: Bool; let release: PublishedUpdate? }
struct UpdateCheckResponse { let license_status: String; let update_available: Bool; let token: String? }
@MainActor enum Calls { static var events: [String] = [] }
@MainActor final class UpdateAPIClient {
    static let origin = URL(string: "https://textlinkeditor.skyprawngo.com")!
    static var release: PublishedUpdate? = nil
    func latest(version: String, build: String) async throws -> ReleaseCheckResponse {
        Calls.events.append("metadata")
        return ReleaseCheckResponse(update_available: Self.release != nil, release: Self.release)
    }
    func check(deviceID: String, appKey: String, version: String, build: String, targetBuild: String?) async throws -> UpdateCheckResponse {
        Calls.events.append("authorize:" + (targetBuild ?? "missing"))
        // Stop before Sparkle installation so this regression never downloads or installs anything.
        return UpdateCheckResponse(license_status: "unlicensed", update_available: false, token: nil)
    }
}
@MainActor enum UpdateIdentity {
    static func read(_ account: String) throws -> String? { Calls.events.append("keychain-read"); return nil }
    static func deviceID() throws -> String { Calls.events.append("device-id"); return "fixture" }
    static func write(_ value: String, account: String) throws { Calls.events.append("keychain-write") }
}
enum L10n { static func get(_ key: String) -> String { key } }
@MainActor final class EditorTabManager {
    static let shared = EditorTabManager()
    let tabs: [String] = []
    func prepareToClose(_ tabs: [String]) -> Bool { true }
    func saveSession(to path: URL, omittingApprovedDiscards: Bool) {}
}
@MainActor final class ProjectManager {
    struct Project { let path: URL }
    static let shared = ProjectManager()
    let currentProject: Project? = nil
}

@main struct WorkflowRegression {
    @MainActor static func main() async {
        let suite = "com.textlinkeditor.update-workflow-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var choice: NSApplication.ModalResponse = .alertSecondButtonReturn
        let makeManager = {
            AppUpdateManager(defaults: defaults, offerPresenter: { update in
                precondition(update.notes == "- Save fix")
                Calls.events.append("offer")
                return choice
            }, statusPresenter: { _, _ in Calls.events.append("status") })
        }
        let manager = makeManager()
        #if DEBUG
        precondition(!AppUpdateManager.isEnabled)
        manager.start()
        await manager.check()
        await manager.saveKey("must-not-write")
        await Task.yield()
        precondition(Calls.events.isEmpty)
        precondition(manager.statusKey == "updates.debugDisabled")
        print("PASS: Debug start/check/save perform no network, Keychain, or presentation")
        #else
        precondition(AppUpdateManager.isEnabled)
        await manager.check(manual: false)
        precondition(Calls.events == ["metadata"])
        UpdateAPIClient.release = PublishedUpdate(build: "2", version: "0.2.0", notes: "- Save fix", minimum_os: "26.0")
        Calls.events = []
        await manager.check(manual: false)
        precondition(Calls.events == ["metadata", "offer"])
        // Skip survives manager recreation. No credential reads on any skipped check.
        Calls.events = []
        let reopened = makeManager()
        await reopened.check(manual: false)
        precondition(Calls.events == ["metadata"])
        choice = .alertThirdButtonReturn
        Calls.events = []
        await reopened.check(manual: true)
        precondition(Calls.events == ["metadata", "offer"])
        UpdateAPIClient.release = PublishedUpdate(build: "3", version: "0.3.0", notes: "- Save fix", minimum_os: "26.0")
        Calls.events = []
        await reopened.check(manual: false)
        precondition(Calls.events == ["metadata", "offer"])
        choice = .alertFirstButtonReturn
        Calls.events = []
        await reopened.check(manual: false)
        precondition(Calls.events == ["metadata", "offer", "device-id", "keychain-read", "authorize:3", "status"])
        print("PASS: metadata-first, persistent skip, manual retry, later, next release, consent before Keychain/auth")
        #endif
    }
}
