import Foundation

enum L10n { static func get(_ key: String) -> String { key } }

@main struct GitRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TextlinkGit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var assertions = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); assertions += 1; print("PASS " + label) }
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
        }
        func write(_ path: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let repo = ProjectGitRepository(project: root)
        check(try !repo.snapshot().exists, "inspection never initializes Git")
        try repo.initialize()
        try git(["config", "user.name", "Fixture"])
        try git(["config", "user.email", "fixture@example.test"])
        try git(["config", "commit.gpgsign", "false"])
        try write("한글 문서.md", "original\n")
        try write("[draft].md", "literal\n")
        try write("d.md", "unrelated\n")
        try write(".private.md", "hidden")
        check(try repo.snapshot().changes.count == 3, "hidden app data excluded")
        let untracked = try repo.diff(path: "한글 문서.md", scope: .working)
        check(untracked.before == nil && untracked.after == "original\n", "untracked text has exact bytes")
        try repo.stage("[draft].md")
        check(try repo.snapshot().changes.filter(\.staged).map(\.path) == ["[draft].md"], "literal pathspec cannot stage neighboring files")
        try repo.unstage("[draft].md")
        check(try repo.snapshot().changes.allSatisfy { !$0.staged }, "unstage works before first commit")
        try repo.stage("한글 문서.md")
        try repo.commit("initial")
        try write("한글 문서.md", "staged\n")
        try repo.stage("한글 문서.md")
        try write("한글 문서.md", "working\n")
        let snapshot = try repo.snapshot()
        let row = snapshot.changes.first { $0.path == "한글 문서.md" }!
        check(row.staged && row.unstaged, "partial staging appears in both groups")
        let staged = try repo.diff(path: row.path, scope: .staged)
        let working = try repo.diff(path: row.path, scope: .working)
        check(staged.before == "original\n" && staged.after == "staged\n", "staged comparison uses HEAD and index")
        check(working.before == "staged\n" && working.after == "working\n", "working comparison uses index and disk")
        check(working.patch.contains("@@") && working.patch.contains("+working"), "unified hunks available for instructions")
        try repo.unstage(row.path)
        check(try String(contentsOf: root.appendingPathComponent(row.path), encoding: .utf8) == "working\n", "unstage preserves working manuscript")
        try repo.stage(row.path)
        try repo.commit("second")
        let history = try repo.snapshot().commits
        check(history.count == 2 && history.first?.parents == [history[1].id], "graph follows actual commit parents")
        check(try repo.commitPatch(history[0].id).contains("+working"), "commit comparison contains source changes")
        try FileManager.default.removeItem(at: root.appendingPathComponent(row.path))
        check(try repo.diff(path: row.path, scope: .working).after == nil, "deleted manuscript is not recreated")
        try Data([0, 255, 1]).write(to: root.appendingPathComponent("image.png"))
        check(try repo.diff(path: "image.png", scope: .working).binary, "binary content is not an AI text change")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: root.appendingPathComponent("d.md"))
        do { _ = try repo.diff(path: "link.md", scope: .working); preconditionFailure("symlink accepted") } catch {}
        check(!ProjectGitRepository.safePath("../outside.md") && !ProjectGitRepository.safePath(".git/config"), "unsafe targets rejected")
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        do { _ = try ProjectGitRepository(project: nested).snapshot(); preconditionFailure("parent Git accepted") } catch {}
        check(true, "parent repository is never managed implicitly")
        do { _ = try repo.pushTarget(); preconditionFailure("missing upstream accepted") } catch ProjectGitError.noUpstream {}
        let remote = root.appendingPathComponent("remote.git")
        try git(["init", "--bare", remote.path])
        try git(["remote", "add", "fixture", remote.path])
        let branch = try repo.snapshot().branch
        try git(["config", "branch.\(branch).remote", "fixture"])
        try git(["config", "branch.\(branch).merge", "refs/heads/published"])
        let target = try repo.pushTarget()
        try repo.push(to: target, expectedHead: repo.head())
        try git(["--git-dir=" + remote.path, "cat-file", "-e", try repo.head()])
        check(true, "explicit upstream receives current commit in local bare fixture")
        do { try repo.push(to: target, expectedHead: "outdated"); preconditionFailure("stale head pushed") } catch ProjectGitError.changed {}
        try git(["config", "branch.\(branch).merge", "refs/heads/different"])
        do { try repo.push(to: target, expectedHead: repo.head()); preconditionFailure("changed upstream pushed") } catch ProjectGitError.changed {}
        check(true, "push rejects changed head or upstream")
        try write(".gitignore", "# keep existing rules\nold-pattern")
        try write("nested/[초안]*?.txt ", "keep manuscript")
        try write("nested/neighbor.txt", "neighbor")
        try write("nested/한글 문서.md", "same basename elsewhere")
        let indexBeforeIgnore = try repo.diff(path: row.path, scope: .staged)
        try repo.ignore("nested/[초안]*?.txt ")
        try repo.ignore("한글 문서.md")
        let ignoreContents = try Data(contentsOf: root.appendingPathComponent(".gitignore"))
        try repo.ignore("한글 문서.md")
        check(try Data(contentsOf: root.appendingPathComponent(".gitignore")) == ignoreContents, "repeated ignore is idempotent")
        check(String(decoding: ignoreContents, as: UTF8.self).hasPrefix("# keep existing rules\nold-pattern\n"), "ignore preserves existing bytes and missing final newline")
        let ignoredSnapshot = try repo.snapshot()
        check(!ignoredSnapshot.changes.contains { $0.path == "nested/[초안]*?.txt " }, "literal wildcard and trailing-space file is ignored")
        check(ignoredSnapshot.changes.contains { $0.path == "nested/neighbor.txt" } && ignoredSnapshot.changes.contains { $0.path == "nested/한글 문서.md" }, "ignore leaves neighboring paths visible")
        check(ignoredSnapshot.changes.contains { $0.path == row.path }, "ignore does not hide a tracked deletion")
        check(try repo.diff(path: row.path, scope: .staged).after == indexBeforeIgnore.after, "ignore preserves the index")
        check(try String(contentsOf: root.appendingPathComponent("nested/[초안]*?.txt "), encoding: .utf8) == "keep manuscript", "ignore preserves manuscript bytes")
        check(ignoredSnapshot.changes.contains { $0.path == ".gitignore" && $0.untracked }, "gitignore is available for staging")
        try repo.stage(".gitignore")
        check(try repo.snapshot().changes.contains { $0.path == ".gitignore" && $0.staged }, "gitignore can be staged")
        try repo.unstage(".gitignore")
        try FileManager.default.removeItem(at: root.appendingPathComponent(".gitignore"))
        try repo.ignore("d.md")
        check(try !repo.snapshot().changes.contains { $0.path == "d.md" }, "missing gitignore is created and applied")
        try FileManager.default.removeItem(at: root.appendingPathComponent(".gitignore"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".gitignore"), withDestinationURL: root.appendingPathComponent("d.md"))
        do { try repo.ignore("d.md"); preconditionFailure("symlink ignore accepted") } catch ProjectGitError.unsafePath {}
        do { try repo.ignore("bad\nname.md"); preconditionFailure("newline ignore accepted") } catch ProjectGitError.unsafePath {}
        check(try String(contentsOf: root.appendingPathComponent("d.md"), encoding: .utf8) == "unrelated\n", "symlink target is preserved")
        print("Git regression passed: \(assertions) assertions")
        let parsed = CommitDiffDocument(patch: """
        commit abc
            Message
        diff --git a/한글 file.md b/한글 file.md
        --- a/한글 file.md
        +++ b/한글 file.md
        @@ -2,2 +2,3 @@ heading
         same
        -old
        +new
        +++literal
        \\ No newline at end of file
        @@ -10 +11 @@
        -second
        +replacement
        diff --git a/image.png b/image.png
        Binary files a/image.png and b/image.png differ
        diff --git a/gone.md b/gone.md
        deleted file mode 100644
        --- a/gone.md
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        """)
        check(parsed.files.count == 3 && parsed.files[0].title == "한글 file.md", "diff groups Unicode and spaced file paths")
        check(parsed.files[0].hunks.count == 2 && parsed.files[0].added == 3 && parsed.files[0].removed == 2, "hunks retain independent change totals")
        let lines = parsed.files[0].hunks[0].lines
        check(lines[0].oldNumber == 2 && lines[0].newNumber == 2 && lines[1].oldNumber == 3 && lines[1].newNumber == nil && lines[2].newNumber == 3,
              "diff tracks old and new line numbers independently")
        check(lines[3].kind == .added && lines[3].text == "+++literal" && lines[4].kind == .note, "content resembling headers and no-newline notes are preserved")
        check(parsed.files[1].hunks.isEmpty && parsed.files[1].metadata.joined().contains("Binary files"), "binary metadata stays visible without fabricated lines")
        check(parsed.files[2].title == "gone.md" && parsed.files[2].removed == 1, "deleted files retain old path")
        check(CommitDiffDocument(patch: "metadata only").summary == "metadata only", "patchless commit summary remains visible")
    }
}
