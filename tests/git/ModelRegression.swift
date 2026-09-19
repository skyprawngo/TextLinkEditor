import Foundation
import Observation

enum L10n { static func get(_ key: String) -> String { key } }
@MainActor final class EditorTabManager {
    static let shared = EditorTabManager()
    func prepareForAIWorkspaceEdit(project: URL) throws {}
}
@MainActor final class CollaborationCoordinator {
    var showingPanel = false
    var error: String?
    func submitVersionChange(path: String, before: String?, after: String?, instruction: String) {}
}
final class ChangeFlag: @unchecked Sendable { var changed = false }

@main struct ModelRegression {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitModel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ProjectGitModel()
        model.setProject(root)
        // Let the initial discovery finish before measuring subsequent refreshes.
        try await Task.sleep(for: .milliseconds(500))
        precondition(!model.snapshot.exists)
        try ProjectGitRepository(project: root).initialize()
        await model.refresh(clearError: false, discoverRepository: false)
        precondition(!model.snapshot.exists, "background refresh must use cached absence")
        await model.refresh()
        precondition(model.snapshot.exists, "explicit refresh must discover external Git initialization")
        let flag = ChangeFlag()
        withObservationTracking {
            _ = model.busy
            _ = model.snapshot
        } onChange: { flag.changed = true }
        for _ in 0..<3 { await model.refresh(clearError: false, discoverRepository: false) }
        precondition(!flag.changed, "unchanged polling must not invalidate controls or lists")
        try "new manuscript".write(to: root.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8)
        await model.refresh(clearError: false, discoverRepository: false)
        precondition(flag.changed && model.snapshot.changes.count == 1, "real changes must still publish")
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        try git(["config", "user.name", "Fixture"])
        try git(["config", "user.email", "fixture@example.test"])
        try git(["config", "commit.gpgsign", "false"])
        let repository = ProjectGitRepository(project: root)
        try repository.stage("draft.md")
        await model.refresh()
        for message in ["", "  \n", "Manual message"] {
            model.commitMessage = message
            precondition(model.canCommit, "message contents must not disable a staged commit")
        }
        model.busy = true
        precondition(!model.canCommit, "in-flight work disables commit")
        model.busy = false
        try "unstaged secret fixture".write(to: root.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8)
        model.commitMessage = "  "
        model.commit { patch in
            precondition(patch.contains("new manuscript") && !patch.contains("unstaged secret fixture"), "generator receives only staged content")
            return "Add manuscript"
        }
        while model.busy { try await Task.sleep(for: .milliseconds(20)) }
        precondition(model.error == nil && model.commitMessage.isEmpty)
        let autoCommitted = try repository.snapshot()
        precondition(autoCommitted.commits.first?.subject == "Add manuscript")
        try repository.stage("draft.md")
        model.commit { _ in throw ProjectGitError.command }
        while model.busy { try await Task.sleep(for: .milliseconds(20)) }
        let afterFailure = try repository.snapshot()
        precondition(model.error != nil && afterFailure.commits.count == 1, "generation failure must not commit")
        model.commit { _ in
            try "changed index".write(to: root.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8)
            try repository.stage("draft.md")
            return "Stale message"
        }
        while model.busy { try await Task.sleep(for: .milliseconds(20)) }
        let afterConflict = try repository.snapshot()
        precondition(model.error != nil && afterConflict.commits.count == 1, "index changes during generation must prevent commit")
        model.commitMessage = "Manual message"
        model.commit { _ in preconditionFailure("manual commit invoked AI") }
        while model.busy { try await Task.sleep(for: .milliseconds(20)) }
        let manualCommitted = try repository.snapshot()
        precondition(manualCommitted.commits.first?.subject == "Manual message")
        print("PASS automatic commit, staged-only input, failure and conflict guards, manual bypass")
        try "push fixture".write(to: root.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8)
        try repository.stage("draft.md")
        model.commitMessage = "Push fixture"
        model.commit(pushAfter: true) { _ in preconditionFailure("manual message invoked AI") }
        while model.busy { try await Task.sleep(for: .milliseconds(20)) }
        let withoutUpstream = try repository.snapshot()
        precondition(withoutUpstream.commits.count == manualCommitted.commits.count, "missing upstream prevents commit-and-push before committing")
        let branch = try repository.snapshot().branch
        let remote = root.appendingPathComponent("remote.git")
        try git(["init", "--bare", remote.path])
        try git(["remote", "add", "fixture", remote.path])
        try git(["config", "branch.\(branch).remote", "fixture"])
        try git(["config", "branch.\(branch).merge", "refs/heads/published"])
        // Keep fetch tracking valid but fail transport locally, without any network access.
        try git(["remote", "set-url", "--push", "fixture", root.appendingPathComponent("missing.git").path])
        model.commit(pushAfter: true) { _ in preconditionFailure("manual message invoked AI") }
        while model.busy { try await Task.sleep(for: .milliseconds(20)) }
        let afterPushFailure = try repository.snapshot()
        precondition(afterPushFailure.commits.count == manualCommitted.commits.count + 1 && model.commitMessage.isEmpty)
        precondition(model.error?.contains("git.committedPushFailed") == true, "failed push reports that local commit was preserved")
        try git(["remote", "set-url", "--push", "fixture", remote.path])
        model.push()
        while model.busy { try await Task.sleep(for: .milliseconds(20)) }
        precondition(model.error == nil)
        let afterRetry = try repository.snapshot()
        precondition(afterRetry.commits.count == afterPushFailure.commits.count, "push retry never duplicates a commit")
        print("PASS commit-and-push preflight, preserved commit on transport failure, push-only retry")
        model.setProject(nil)
        model.setProject(root)
        try await Task.sleep(for: .milliseconds(500))
        precondition(model.snapshot.exists, "reopening project must rediscover Git")
        model.setProject(nil)
        print("Git model regression passed: cached discovery, silent polling, changed publication, project reopen")
    }
}
