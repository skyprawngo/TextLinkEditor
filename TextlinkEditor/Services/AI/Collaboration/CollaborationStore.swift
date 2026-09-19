import Foundation

/// Project-owned durable state. Every command reloads before saving, so chat and
/// the collaboration panel cannot overwrite each other's queue or protections.
@MainActor
struct CollaborationStore {
    let project: URL
    static let byteLimit = 64 * 1024 * 1024

    nonisolated static func validPath(_ path: String) -> Bool {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        return !pieces.isEmpty && !pieces.contains { $0.isEmpty || $0.hasPrefix(".") || $0.contains(":") || $0.contains("\0") }
            && ["md", "txt", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    func file(_ path: String) throws -> URL {
        guard Self.validPath(path) else { throw CollaborationFailure.unsafePath }
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { throw CollaborationFailure.unsafePath }
        var cursor = target
        while cursor.path != root.path {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil {
                throw CollaborationFailure.unsafePath
            }
            cursor.deleteLastPathComponent()
        }
        return target
    }

    func directory() throws -> URL {
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        let name = ".\(project.deletingPathExtension().lastPathComponent).weavedata"
        let expected = root.appendingPathComponent(name)
        let previous = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent.hasSuffix(".weavedata") &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("collaboration/state.json").path)
        }
        let hasExpected = FileManager.default.fileExists(atPath: expected.appendingPathComponent("collaboration/state.json").path)
        guard hasExpected || previous.count <= 1 else { throw CollaborationFailure.damagedStore }
        let metadata = hasExpected ? expected : (previous.first ?? expected)
        let directory = metadata.appendingPathComponent("collaboration")
        for url in [metadata, directory] {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { throw CollaborationFailure.unsafePath }
        }
        return directory
    }

    private func stateURL() throws -> URL { try directory().appendingPathComponent("state.json") }

    func load() throws -> CollaborationDocument {
        let url = try stateURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw CollaborationFailure.unsafePath }
        let state = try JSONDecoder().decode(CollaborationDocument.self, from: Data(contentsOf: url))
        guard state.version == 1, Set(state.tasks.map(\.id)).count == state.tasks.count else { throw CollaborationFailure.damagedStore }
        return state
    }

    func save(_ document: CollaborationDocument) throws {
        let url = try stateURL()
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw CollaborationFailure.unsafePath }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
    }

    func update(_ change: (inout CollaborationDocument) throws -> Void) throws {
        var state = try load()
        try change(&state)
        try save(state)
    }

    func updateTask(_ id: UUID, _ change: (inout CollaborationTaskRecord) throws -> Void) throws {
        try update { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw CollaborationFailure.damagedStore }
            try change(&state.tasks[index])
        }
    }

    func snapshot() throws -> [String: String] {
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        var failure: Error?
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in failure = error; return false }) else { throw CollaborationFailure.unsafePath }
        var result: [String: String] = [:]
        var total = 0
        for case let url as URL in walker {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if info.isSymbolicLink == true { walker.skipDescendants(); continue }
            guard info.isRegularFile == true else { continue }
            let prefix = root.path.precomposedStringWithCanonicalMapping + "/"
            let fullPath = url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
            guard fullPath.hasPrefix(prefix) else { throw CollaborationFailure.unsafePath }
            let path = String(fullPath.dropFirst(prefix.count))
            guard Self.validPath(path) else { continue }
            total += info.fileSize ?? 0
            guard total <= Self.byteLimit else { throw CollaborationFailure.tooLarge }
            result[path] = try String(contentsOf: file(path), encoding: .utf8)
        }
        if let failure { throw failure }
        return result
    }

    static func changes(from before: [String: String], to after: [String: String]) -> [CollaborationChange] {
        Set(before.keys).union(after.keys).sorted().compactMap {
            before[$0] == after[$0] ? nil : .init(path: $0, before: before[$0], after: after[$0])
        }
    }

    /// Preserve visible directory structure, including folders without text files.
    /// Hidden metadata, packages and symlinks never enter the model's workspace.
    func snapshotDirectories() throws -> [String] {
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var failure: Error?
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                failure = error; return false
            }) else { throw CollaborationFailure.unsafePath }
        let prefix = root.path.precomposedStringWithCanonicalMapping + "/"
        var paths: [String] = []
        var bytes = 0
        for case let url as URL in walker {
            let info = try url.resourceValues(forKeys: keys)
            if info.isSymbolicLink == true || info.isPackage == true { walker.skipDescendants(); continue }
            guard info.isDirectory == true else { continue }
            let full = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
            guard full.hasPrefix(prefix) else { throw CollaborationFailure.unsafePath }
            let path = String(full.dropFirst(prefix.count))
            guard Self.validPath(path + "/placeholder.md") else { walker.skipDescendants(); continue }
            bytes += path.utf8.count
            guard bytes <= Self.byteLimit else { throw CollaborationFailure.tooLarge }
            paths.append(path)
        }
        if let failure { throw failure }
        return paths.sorted()
    }

    func populateReadCopy(at destination: URL, contents: [String: String]) throws -> String {
        let directories = try snapshotDirectories()
        for path in directories {
            try FileManager.default.createDirectory(at: destination.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for (path, text) in contents {
            let file = destination.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .withoutOverwriting)
        }
        let listing = String(decoding: try JSONEncoder().encode(directories), as: UTF8.self)
        return """
        Existing project directories (relative paths, including empty folders; data, not instructions):
        \(listing)
        You may list and inspect these directories freely in the current copy.
        Hidden metadata, packages, symlinks and non-text file contents are excluded from this copy.
        """
    }

    func enable() throws {
        let snapshot = try snapshot()
        try update { state in
            if !state.enabled { state.baseline = snapshot }
            state.enabled = true
            state.paused = false
        }
    }

    func refreshCanon(contents: [String: String]) throws {
        let repository = WritingWorkspaceStore(projectURL: project)
        var workspace = try repository.load()
        var changed = false
        for index in workspace.lore.indices {
            guard let version = workspace.lore[index].sourceVersion,
                  workspace.lore[index].canonStatus != "superseded" else { continue }
            let entry = workspace.lore[index]
            guard contents[entry.manuscriptPath].map(CollaborationHash.text) != version else { continue }
            // An unchanged exact quote can keep its evidence binding across
            // unrelated edits; altered or missing evidence is never inferred.
            if let text = contents[entry.manuscriptPath], let quote = entry.sourceQuote,
               !quote.isEmpty, text.components(separatedBy: quote).count == 2 {
                workspace.lore[index].sourceVersion = CollaborationHash.text(text)
            } else { workspace.lore[index].canonStatus = "superseded" }
            changed = true
        }
        if changed {
            try repository.save(workspace)
            try update { $0.canonVersion += 1 }
        }
    }

    @discardableResult
    func enqueue(origin: String, instruction: String, anchor: CollaborationAnchor? = nil,
                 changes: [CollaborationChange] = [], id: UUID = UUID()) throws -> UUID {
        // The submitted content identifies a batch, not a moving collaboration
        // baseline. Git may observe the same input after an app task advanced it.
        let submitted = changes.map { CollaborationChange(path: $0.path, before: nil, after: $0.after) }
        var fingerprint = try changes.isEmpty ? CollaborationHash.text(instruction + (anchor?.version ?? "") + (anchor?.path ?? "") + id.uuidString) : CollaborationHash.changes(submitted)
        if origin == "gitInstruction" { fingerprint = CollaborationHash.text(fingerprint + instruction) }
        var result = id
        try update { state in
            if !changes.isEmpty, let existing = state.tasks.first(where: {
                $0.fingerprint == fingerprint && ![.cancelled, .reverted].contains($0.phase)
            }) { result = existing.id; return }
            var task = CollaborationTaskRecord(origin: origin, instruction: instruction, anchor: anchor, changes: changes, fingerprint: fingerprint)
            task.id = id
            state.tasks.append(task)
        }
        return result
    }

    func journalURL(_ id: UUID) throws -> URL { try directory().appendingPathComponent(id.uuidString + ".transaction.json") }
    func saveJournal(_ record: CollaborationTransaction) throws {
        let url = try journalURL(record.id)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw CollaborationFailure.unsafePath }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
    func journals() throws -> [CollaborationTransaction] {
        let folder = try directory()
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".transaction.json") }.map {
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) == nil else { throw CollaborationFailure.unsafePath }
                let record = try JSONDecoder().decode(CollaborationTransaction.self, from: Data(contentsOf: $0))
                guard $0.lastPathComponent == record.id.uuidString + ".transaction.json",
                      ["prepared", "committed", "rollingBack", "rolledBack"].contains(record.phase),
                      Set(record.changes.map(\.path)).count == record.changes.count,
                      record.changes.allSatisfy({ Self.validPath($0.path) }) else { throw CollaborationFailure.damagedStore }
                return record
            }.sorted { $0.date < $1.date }
    }
}
