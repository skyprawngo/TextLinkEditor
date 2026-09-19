import Foundation

struct ProjectGitChange: Identifiable, Equatable, Sendable {
    var path: String
    var index: String
    var worktree: String
    var id: String { path }
    var untracked: Bool { index == "?" && worktree == "?" }
    var staged: Bool { index != " " && index != "?" }
    var unstaged: Bool { worktree != " " }
    var isText: Bool { ["md", "txt", "markdown"].contains((path as NSString).pathExtension.lowercased()) }
}

struct ProjectGitCommit: Identifiable, Equatable, Sendable {
    let id: String
    let parents: [String]
    let refs: String
    let subject: String
    let author: String
    let date: String
    var lane = 0
    var lines: [ProjectGitLine] = []
}
struct ProjectGitLine: Equatable, Sendable { let from: Int; let to: Int }
struct ProjectGitSnapshot: Equatable, Sendable {
    var exists = false
    var branch = ""
    var changes: [ProjectGitChange] = []
    var commits: [ProjectGitCommit] = []
}
struct ProjectGitCommitInput: Equatable, Sendable {
    let index: String
    let head: String
    let patch: String
}
enum ProjectGitScope: String, CaseIterable, Identifiable, Sendable {
    case working, staged
    var id: String { rawValue }
    var title: String { L10n.get("git." + rawValue) }
}
struct ProjectGitDiff: Identifiable, Sendable {
    var id: String { scope.rawValue + ":" + path }
    let path: String
    let scope: ProjectGitScope
    let before: String?
    let after: String?
    let patch: String
    let binary: Bool
}

enum ProjectGitError: LocalizedError {
    case command, rootMismatch, unsafePath, changed, binary, tooLarge, noUpstream, pushFailed
    var errorDescription: String? { L10n.get("git.error." + String(describing: self)) }
}

/// Argument-only Git access. Never creates a repository or changes the index
/// during inspection. App metadata and symlinks are not document targets.
struct ProjectGitRepository: Sendable {
    struct PushTarget: Equatable, Sendable { let branch: String; let remote: String; let ref: String }
    let project: URL
    static func safePath(_ path: String) -> Bool {
        path == ".gitignore" || !path.isEmpty && !path.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0.isEmpty || $0.hasPrefix(".") || $0.contains("\0") || $0.contains(":")
        }
    }
    func file(_ path: String) throws -> URL {
        guard Self.safePath(path) else { throw ProjectGitError.unsafePath }
        let root = project.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path)
        var cursor = url
        while cursor.path != root.path {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) == nil else { throw ProjectGitError.unsafePath }
            cursor.deleteLastPathComponent()
        }
        return url
    }
    func validateRoot() throws -> Bool {
        guard let data = try? run(["rev-parse", "--show-toplevel"]) else { return false }
        let root = URL(fileURLWithPath: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        guard root.resolvingSymlinksInPath().standardizedFileURL == project.resolvingSymlinksInPath().standardizedFileURL else {
            throw ProjectGitError.rootMismatch
        }
        return true
    }
    func snapshot(repositoryExists: Bool? = nil) throws -> ProjectGitSnapshot {
        let exists = try repositoryExists ?? validateRoot()
        guard exists else { return .init() }
        // A cached root must never fall back to an enclosing repository if .git is removed.
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent(".git").path) else {
            throw ProjectGitError.changed
        }
        let branch = (try? text(["symbolic-ref", "--short", "HEAD"])) ?? ((try? text(["rev-parse", "--short", "HEAD"])) ?? "HEAD")
        let data = try run(["-c", "status.renames=false", "status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let changes = try Self.parseStatus(data)
        let hasHead = (try? run(["rev-parse", "--verify", "HEAD"])) != nil
        var commits: [ProjectGitCommit] = []
        if hasHead {
            let log = try text(["log", "--all", "--topo-order", "-100", "--date=short", "--format=%H%x1f%P%x1f%D%x1f%s%x1f%an%x1f%ad%x1e"])
            commits = log.split(separator: "\u{1e}").compactMap { record in
                let fields = record.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
                guard fields.count == 6 else { return nil }
                return .init(id: fields[0], parents: fields[1].split(separator: " ").map(String.init), refs: fields[2], subject: fields[3], author: fields[4], date: fields[5])
            }
            var lanes: [String] = []
            for i in commits.indices {
                let item = commits[i]
                if !lanes.contains(item.id) { lanes.append(item.id) }
                let lane = lanes.firstIndex(of: item.id)!
                let old = lanes
                lanes.remove(at: lane)
                for (offset, parent) in item.parents.enumerated() where !lanes.contains(parent) {
                    lanes.insert(parent, at: min(lane + offset, lanes.count))
                }
                commits[i].lane = lane
                commits[i].lines = old.enumerated().flatMap { index, hash -> [ProjectGitLine] in
                    let targets = hash == item.id ? item.parents : [hash]
                    return targets.compactMap { hash in lanes.firstIndex(of: hash).map { .init(from: index, to: $0) } }
                }
            }
        }
        return .init(exists: true, branch: branch, changes: changes, commits: commits)
    }
    static func parseStatus(_ data: Data) throws -> [ProjectGitChange] {
        try data.split(separator: 0).compactMap { bytes in
            guard bytes.count >= 4, let value = String(data: Data(bytes), encoding: .utf8) else { throw ProjectGitError.command }
            let path = String(value.dropFirst(3)).precomposedStringWithCanonicalMapping
            guard safePath(path) else { return nil }
            return .init(path: path, index: String(value.prefix(1)), worktree: String(value.dropFirst().prefix(1)))
        }.sorted { $0.path < $1.path }
    }
    private func blob(_ path: String, staged: Bool) throws -> Data? {
        _ = try file(path)
        let entries: Data
        if staged { entries = try run(["ls-files", "--stage", "-z", "--", path]) }
        else {
            guard (try? run(["rev-parse", "--verify", "HEAD"])) != nil else { return nil }
            entries = try run(["ls-tree", "-z", "HEAD", "--", path])
        }
        guard !entries.isEmpty else { return nil }
        let row = String(decoding: entries, as: UTF8.self)
        guard row.hasPrefix("100644 ") || row.hasPrefix("100755 ") else { throw ProjectGitError.unsafePath }
        if staged, row.split(separator: "\t", maxSplits: 1).first?.hasSuffix(" 0") != true { throw ProjectGitError.changed }
        return try run(["show", (staged ? ":" : "HEAD:") + path])
    }
    func diff(path: String, scope: ProjectGitScope) throws -> ProjectGitDiff {
        guard try validateRoot() else { throw ProjectGitError.command }
        let url = try file(path)
        let before = try blob(path, staged: scope == .working)
        let after: Data?
        if scope == .staged { after = try blob(path, staged: true) }
        else {
            if FileManager.default.fileExists(atPath: url.path) {
                guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 64 * 1024 * 1024 else { throw ProjectGitError.tooLarge }
                after = try Data(contentsOf: url)
            } else { after = nil }
        }
        let binary = [before, after].compactMap { $0 }.contains { $0.contains(0) || String(data: $0, encoding: .utf8) == nil }
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames"]
        if scope == .staged { args.append("--cached") }
        let patch = try text(args + ["--", path])
        return .init(path: path, scope: scope, before: before.flatMap { String(data: $0, encoding: .utf8) },
                     after: after.flatMap { String(data: $0, encoding: .utf8) }, patch: patch, binary: binary)
    }
    func initialize() throws {
        guard try !validateRoot() else { return }
        _ = try run(["init"])
    }
    func stage(_ path: String) throws {
        guard try validateRoot() else { throw ProjectGitError.command }
        _ = try file(path)
        _ = try run(["--literal-pathspecs", "add", "--", path])
    }
    /// Add an exact, root-relative rule without changing the index or manuscript.
    func ignore(_ path: String) throws {
        guard try validateRoot() else { throw ProjectGitError.command }
        _ = try file(path)
        guard path != ".gitignore", !path.contains("\n"), !path.contains("\r") else { throw ProjectGitError.unsafePath }
        let url = try file(".gitignore")
        var contents = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
        // Git patterns interpret wildcards and trailing spaces unless escaped.
        let escaped = path.reduce(into: "") { result, character in
            if "\\*?[] !#".contains(character) { result.append("\\") }
            result.append(character)
        }
        let rule = Data(("/" + escaped).utf8)
        if contents.split(separator: 10).last == rule { return }
        if !contents.isEmpty && contents.last != 10 { contents.append(10) }
        contents.append(rule)
        contents.append(10)
        try contents.write(to: url, options: .atomic)
    }
    func unstage(_ path: String) throws {
        guard try validateRoot() else { throw ProjectGitError.command }
        _ = try file(path)
        if (try? run(["rev-parse", "--verify", "HEAD"])) != nil {
            _ = try run(["--literal-pathspecs", "reset", "-q", "HEAD", "--", path])
        } else { _ = try run(["--literal-pathspecs", "rm", "--cached", "--", path]) }
    }
    func commit(_ message: String) throws {
        guard try validateRoot(), !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectGitError.command }
        let paths = try run(["diff", "--cached", "--name-only", "-z"]).split(separator: 0)
        guard !paths.isEmpty, paths.allSatisfy({ Self.safePath(String(decoding: $0, as: UTF8.self)) }) else { throw ProjectGitError.unsafePath }
        _ = try run(["commit", "-m", message])
    }
    func commitInput() throws -> ProjectGitCommitInput {
        guard try validateRoot() else { throw ProjectGitError.command }
        let paths = try run(["diff", "--cached", "--name-only", "-z"]).split(separator: 0)
        guard !paths.isEmpty, paths.allSatisfy({ Self.safePath(String(decoding: $0, as: UTF8.self)) }) else { throw ProjectGitError.unsafePath }
        let patch = try text(["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--"])
        guard patch.utf8.count <= 500_000 else { throw ProjectGitError.tooLarge }
        return .init(index: try text(["ls-files", "--stage", "-z"]),
                     head: ((try? text(["rev-parse", "--verify", "HEAD"])) ?? "") + "\n" + ((try? text(["symbolic-ref", "HEAD"])) ?? ""), patch: patch)
    }
    func commit(_ message: String, matching input: ProjectGitCommitInput) throws {
        guard try commitInput() == input else { throw ProjectGitError.changed }
        try commit(message)
    }
    func commitPatch(_ id: String) throws -> String {
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit }), try validateRoot() else { throw ProjectGitError.unsafePath }
        return try text(["show", "--no-ext-diff", "--no-textconv", "--format=fuller", "--stat", "--patch", id, "--"])
    }
    func pushTarget() throws -> PushTarget {
        guard try validateRoot(), let branch = try? text(["symbolic-ref", "HEAD"]), branch.hasPrefix("refs/heads/") else { throw ProjectGitError.noUpstream }
        let remote = try text(["for-each-ref", "--format=%(upstream:remotename)", branch])
        let ref = try text(["for-each-ref", "--format=%(upstream:remoteref)", branch])
        guard !remote.isEmpty, remote != ".", !remote.hasPrefix("-"), ref.hasPrefix("refs/heads/") else { throw ProjectGitError.noUpstream }
        return .init(branch: branch, remote: remote, ref: ref)
    }
    func head() throws -> String { try text(["rev-parse", "--verify", "HEAD"]) }
    func push(to target: PushTarget, expectedHead: String) throws {
        guard try pushTarget() == target, try head() == expectedHead else { throw ProjectGitError.changed }
        // Explicit refspec avoids push.default/matching and never forces a remote rewrite.
        do { _ = try run(["-c", "remote.\(target.remote).mirror=false", "push", "--no-follow-tags", "--", target.remote, expectedHead + ":" + target.ref]) }
        catch { throw ProjectGitError.pushFailed }
    }
    private func text(_ args: [String]) throws -> String { String(decoding: try run(args), as: UTF8.self).trimmingCharacters(in: .newlines) }
    private func run(_ args: [String]) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.quotepath=false"] + args
        process.currentDirectoryURL = project
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        var result = Data()
        while let part = try pipe.fileHandleForReading.read(upToCount: 65536), !part.isEmpty {
            result.append(part)
            guard result.count <= 64 * 1024 * 1024 else { process.terminate(); throw ProjectGitError.tooLarge }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProjectGitError.command }
        return result
    }
}
