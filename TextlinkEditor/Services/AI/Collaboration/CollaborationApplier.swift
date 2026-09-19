import Foundation

/// Only the app publishes proposals. A journal is durable before any manuscript
/// write. Recovery never overwrites a value other than this transaction's output.
@MainActor
struct CollaborationApplier {
    let store: CollaborationStore
    var checkEditor: () throws -> Void = {}

    func apply(taskID: UUID, before: [String: String], changes: [CollaborationChange]) throws -> UUID? {
        try checkEditor()
        let current = try store.snapshot()
        let protections = try store.load().protectedPaths
        guard Set(changes.map(\.path)).count == changes.count else { throw CollaborationFailure.invalidResponse }
        for change in changes {
            _ = try store.file(change.path)
            guard !protections.contains(change.path), before[change.path] == change.before else { throw CollaborationFailure.conflict }
        }
        // Rebase only files touched by this proposal. Journal actual pre/post images,
        // so rollback and Undo preserve edits made while the provider was responding.
        let changes = try changes.compactMap { change -> CollaborationChange? in
            let latest = current[change.path]
            let merged: String?
            if let base = change.before, let proposed = change.after, let latest {
                do { merged = try ManuscriptTextMerge.merge(base: base, current: latest, proposed: proposed,
                                                           allowingProposedDeletions: true) }
                catch { throw CollaborationFailure.conflict }
            } else {
                // Creating/deleting a file still requires exact ownership.
                guard latest == change.before else { throw CollaborationFailure.conflict }
                merged = change.after
            }
            return latest == merged ? nil : CollaborationChange(path: change.path, before: latest, after: merged)
        }
        guard !changes.isEmpty else { return nil }
        var record = CollaborationTransaction(taskID: taskID, changes: changes)
        try store.saveJournal(record)
        try store.updateTask(taskID) { task in
            task.phase = .applying
            task.transactionIDs.append(record.id)
        }
        do {
            for change in changes {
                try checkEditor()
                try write(change.after, replacing: change.before, path: change.path)
            }
            record.phase = "committed"
            try store.saveJournal(record)
        } catch {
            do { try rollback(&record) }
            catch { throw CollaborationFailure.conflict }
            throw error
        }
        for change in changes {
            WorkspaceFileEvents.shared.publish(.init(url: try store.file(change.path),
                change: change.after == nil ? .trashed : (change.before == nil ? .created : .saved),
                originTaskID: taskID))
        }
        NotificationCenter.default.post(name: .init("aiWorkspaceFilesDidChange"), object: store.project,
                                        userInfo: ["requestID": taskID])
        return record.id
    }

    private func read(_ path: String) throws -> String? {
        let url = try store.file(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ content: String?, replacing expected: String?, path: String) throws {
        let url = try store.file(path)
        guard try read(path) == expected else { throw CollaborationFailure.conflict }
        if let content {
            if let expected {
                try DocumentFileStore.save(content, at: url, expected: expected, events: nil)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try store.file(path)
                try DocumentFileStore.create(content, at: url, events: nil)
            }
        } else if expected != nil {
            let coordinator = NSFileCoordinator()
            var failure: NSError?
            var writeFailure: Error?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &failure) { target in
                do {
                    guard try String(contentsOf: target, encoding: .utf8) == expected else { throw CollaborationFailure.conflict }
                    try FileManager.default.removeItem(at: target)
                } catch { writeFailure = error }
            }
            if let failure { throw failure }
            if let writeFailure { throw writeFailure }
        }
    }

    private func rollback(_ record: inout CollaborationTransaction) throws {
        record.phase = "rollingBack"
        try store.saveJournal(record)
        for change in record.changes.reversed() {
            let current = try read(change.path)
            if current == change.before { continue }
            guard current == change.after else { throw CollaborationFailure.conflict }
            try write(change.before, replacing: change.after, path: change.path)
        }
        record.phase = "rolledBack"
        try store.saveJournal(record)
    }

    func recover() throws {
        try checkEditor()
        for var record in try store.journals() where ["prepared", "rollingBack"].contains(record.phase) {
            try rollback(&record)
        }
        try store.update { document in
            for index in document.tasks.indices where document.tasks[index].phase.isRunning {
                document.tasks[index].phase = .review
                document.tasks[index].error = L10n.get("collaboration.interrupted")
            }
        }
    }

    func undo(taskID: UUID) throws {
        guard let task = try store.load().tasks.first(where: { $0.id == taskID }),
              !task.phase.isRunning, task.phase != .reverted else { throw CollaborationFailure.busy }
        let records = try store.journals().filter { $0.taskID == taskID && $0.phase == "committed" }
        let current = try store.snapshot()
        var desired = current
        for record in records.reversed() {
            for change in record.changes {
                if let after = change.after, let before = change.before, let latest = desired[change.path] {
                    do { desired[change.path] = try ManuscriptTextMerge.merge(base: after, current: latest, proposed: before) }
                    catch { throw CollaborationFailure.conflict }
                } else {
                    guard desired[change.path] == change.after else { throw CollaborationFailure.conflict }
                    desired[change.path] = change.before
                }
            }
        }
        let changes = CollaborationStore.changes(from: current, to: desired)
        _ = try apply(taskID: taskID, before: current, changes: changes)
        try store.update { document in
            for change in changes { document.baseline[change.path] = change.after }
            if let index = document.tasks.firstIndex(where: { $0.id == taskID }) { document.tasks[index].phase = .reverted }
            document.canonVersion += 1
        }
        try store.refreshCanon(contents: desired)
    }
}
