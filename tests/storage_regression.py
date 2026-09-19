#!/usr/bin/env python3
"""Run production storage/tab code with isolated dialog/settings doubles, no app preferences."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
swift = r'''
import Foundation
import AppKit
import Observation

final class NSAlert {
    enum Style { case warning }
    static var responses: [NSApplication.ModalResponse] = []
    var messageText = "", informativeText = ""
    var alertStyle: Style = .warning
    func addButton(withTitle: String) {}
    @discardableResult func runModal() -> NSApplication.ModalResponse {
        Self.responses.isEmpty ? .alertFirstButtonReturn : Self.responses.removeFirst()
    }
}
enum L10n {
    static func get(_ s: String) -> String { s }
    enum common { static let cancel = "Cancel", confirm = "OK" }
    enum editor { static let untitled = "Untitled" }
}
struct UserSettings {
    static let shared = UserSettings()
    let editorFontName = "system"
    let editorFontSize: CGFloat = 14, editorLineSpacing: CGFloat = 1
}
enum ProjectManager { static let dataFolderExtension = "weavedata" }
final class FileSystemItem {
    let url: URL
    var name: String
    let isDirectory: Bool
    init(url: URL, isDirectory: Bool) { self.url = url; name = url.lastPathComponent; self.isDirectory = isDirectory }
}
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError(label) }
    print("PASS " + label)
}
let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }
let project = base.appendingPathComponent("Novel.weaveproj")
let data = project.appendingPathComponent(".Novel.weavedata")
try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
let file = project.appendingPathComponent("chapter.md")
try DocumentFileStore.create("original", at: file)
do { try DocumentFileStore.create("", at: file); fatalError("overwrote original") } catch {}
expect(try! String(contentsOf: file, encoding: .utf8) == "original", "exclusive creation preserves existing document")
try DocumentFileStore.save("saved", at: file, expected: "original")
do { try DocumentFileStore.save("lost", at: file, expected: "original"); fatalError("ignored conflict") } catch {}
expect(try! String(contentsOf: file, encoding: .utf8) == "saved", "conflicting disk revision is preserved")
expect(!DocumentFileStore.contains(base.appendingPathComponent("Novel.weaveproj-other/chapter.md"), in: project), "path boundary is directory-aware")
expect(DocumentFileStore.changedLines(from: "a\nb\nc", to: "a\nnew\nc") == [2], "linear diff reports modified region")
expect(DocumentFileStore.changedLines(from: String(repeating: "a\n", count: 10000), to: "x").count == 1, "long document diff is bounded")
let localRecovery = base.appendingPathComponent("Recovery")
let manager = EditorTabManager(recoveryDirectory: localRecovery)
manager.restoreSession(from: project)
manager.openFile(FileSystemItem(url: file, isDirectory: false))
manager.setEditState(TabEditState(content: "draft", originalContent: "saved"), for: file)
manager.saveSession(to: project)
manager.closeAllTabs(force: true)
// force close writes a new session, so restore the captured crash snapshot explicitly.
manager.openFile(FileSystemItem(url: file, isDirectory: false))
manager.setEditState(TabEditState(content: "draft", originalContent: "saved"), for: file)
manager.saveSession(to: project)
manager.restoreSession(from: project)
expect(manager.getCachedContent(for: file) == "draft", "unsaved crash snapshot restores")
expect(manager.isModified(url: file), "recovered draft remains unsaved")
NSAlert.responses = [.alertThirdButtonReturn]
expect(!manager.prepareToClose(manager.tabs), "cancel rejects close")
expect(manager.getCachedContent(for: file) == "draft", "cancel preserves draft")
NSAlert.responses = [.alertSecondButtonReturn]
expect(manager.prepareToClose(manager.tabs), "discard decision accepted")
expect(manager.getCachedContent(for: file) == "draft", "prepare does not destroy draft before I/O succeeds")
try Data("external".utf8).write(to: file, options: .atomic)
expect(!manager.saveTab(at: 0, content: "draft"), "manager refuses external conflict")
expect(manager.getCachedContent(for: file) == "draft", "failed save retains draft")
expect(manager.saveErrors[file] != nil, "failed save exposes error")
let target = project.appendingPathComponent("renamed.md")
let id = manager.tabs[0].id
try FileManager.default.moveItem(at: file, to: target)
manager.relocateTabs(from: file, to: target)
expect(manager.tabs[0].id == id && manager.tabs[0].url == target, "rename retains document identity")
expect(manager.getCachedContent(for: target) == "draft" && manager.getCachedContent(for: file) == nil, "rename moves cache ownership")
let external = base.appendingPathComponent("outside.md")
try DocumentFileStore.create("outside", at: external)
manager.openFile(FileSystemItem(url: external, isDirectory: false))
manager.setEditState(TabEditState(content: "outside draft", originalContent: "outside"), for: external)
manager.saveSession(to: project)
manager.restoreSession(from: project)
expect(manager.getCachedContent(for: external) == "outside draft", "external document draft restores")
let emptyProject = base.appendingPathComponent("Empty.weaveproj")
try FileManager.default.createDirectory(at: emptyProject, withIntermediateDirectories: true)
manager.restoreSession(from: emptyProject)
expect(manager.tabs.isEmpty, "project without session clears old workspace")
let sessionFile = data.appendingPathComponent("editor-session.json")
try Data("broken json".utf8).write(to: sessionFile)
for url in try FileManager.default.contentsOfDirectory(at: localRecovery, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: url) }
manager.restoreSession(from: project)
expect(manager.recoveryError != nil, "corrupt recovery is reported")
expect(try! FileManager.default.contentsOfDirectory(atPath: data.path).contains(where: { $0.contains("unreadable-") }), "corrupt original is archived")
var forged = TabState(relativePath: "ignored", isModified: true)
forged.externalURL = external
forged.draftContent = "forged"
forged.baseContent = "outside"
try JSONEncoder().encode(EditorSessionState(tabs: [forged], selectedTabIndex: 0)).write(to: sessionFile)
manager.restoreSession(from: project)
expect(manager.tabs.isEmpty, "project metadata cannot inject external write targets")

let largeURL = base.appendingPathComponent("large-utf8.md")
let largeOriginal = String(repeating: "한😀e\u{301}\n", count: 30000)
try DocumentFileStore.create(largeOriginal, at: largeURL)
let largeChanged = largeOriginal + "final\n"
try DocumentFileStore.save(largeChanged, at: largeURL, expected: largeOriginal)
expect(try! String(contentsOf: largeURL, encoding: .utf8) == largeChanged, "streamed atomic save preserves UTF8 chunk boundaries")
let aiFile = project.appendingPathComponent("ai-save.md")
try DocumentFileStore.create("disk", at: aiFile)
manager.openFile(FileSystemItem(url: aiFile, isDirectory: false))
manager.setEditState(TabEditState(content: "visible draft", originalContent: "disk"), for: aiFile)
try manager.prepareForAIWorkspaceEdit(project: project)
expect(try! String(contentsOf: aiFile, encoding: .utf8) == "visible draft", "AI preflight saves visible draft before external editing")
manager.setEditState(TabEditState(content: "unsaved", originalContent: "visible draft"), for: aiFile)
try "external".write(to: aiFile, atomically: true, encoding: .utf8)
do { try manager.prepareForAIWorkspaceEdit(project: project); fatalError("AI ignored draft conflict") } catch {}
expect(manager.getCachedContent(for: aiFile) == "unsaved", "AI preflight preserves conflicting draft")
expect(try! String(contentsOf: aiFile, encoding: .utf8) == "external", "AI preflight does not overwrite external changes")
// Cache mutations must not invalidate tab/sidebar observation after the dirty flag is set.
let isolation = EditorTabManager(recoveryDirectory: base.appendingPathComponent("IsolationRecovery"))
isolation.restoreSession(from: project)
isolation.closeAllTabs(force: true)
isolation.openFile(FileSystemItem(url: file, isDirectory: false))
isolation.setEditState(TabEditState(content: "draft", originalContent: "saved"), for: file)
var tabInvalidations = 0
withObservationTracking {
    _ = isolation.tabs
    _ = isolation.getCachedContent(for: file)
    _ = isolation.getCachedCursorPosition(for: file)
} onChange: { tabInvalidations += 1 }
isolation.setCachedCursorPosition(line: 40000, column: 5, for: file)
isolation.setCachedContent("another draft", for: file)
expect(tabInvalidations == 0, "editing cache and cursor do not invalidate tab observers")
isolation.setCachedContent("saved", for: file)
expect(tabInvalidations == 1, "returning to saved contents updates tab dirty indicator")
let largeDraft = String(repeating: "한글 😀 paragraph\n", count: 100000)
isolation.setCachedContent(largeDraft, for: file)
isolation.recoveryError = "pending"
let queuedAt = Date()
isolation.saveSession(to: project, asynchronously: true)
print("TIME enqueue 100000-line recovery: \(Date().timeIntervalSince(queuedAt) * 1000) ms")
var pulses = 0
let timer = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { _ in pulses += 1 }
let deadline = Date().addingTimeInterval(10)
while isolation.recoveryError == "pending", Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.002))
}
timer.invalidate()
expect(isolation.recoveryError == nil && pulses > 0, "main run loop continues during background recovery encoding and disk writes")
print("RECOVERY main-loop pulses \(pulses)")
isolation.saveSession(to: project, asynchronously: true)
isolation.setCachedContent("newest snapshot", for: file)
isolation.saveSession(to: project)
isolation.restoreSession(from: project)
expect(isolation.getCachedContent(for: file) == "newest snapshot", "explicit save follows queued autosave without stale overwrite")

// External synchronization: use real files, presenters, vnode events and the main run loop.
func waitFor(_ label: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(8)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    expect(condition(), label)
}
let syncProject = base.appendingPathComponent("Sync.weaveproj")
try FileManager.default.createDirectory(at: syncProject.appendingPathComponent(".Sync.weavedata"), withIntermediateDirectories: true)
let sync = EditorTabManager(recoveryDirectory: base.appendingPathComponent("sync-recovery"))
sync.restoreSession(from: syncProject)
let first = syncProject.appendingPathComponent("first.md")
let second = syncProject.appendingPathComponent("second.md")
try DocumentFileStore.create("base", at: first)
try DocumentFileStore.create("other", at: second)
sync.openFile(FileSystemItem(url: first, isDirectory: false))
sync.setEditState(TabEditState(content: "base", originalContent: "base"), for: first)
sync.openFile(FileSystemItem(url: second, isDirectory: false))
sync.setEditState(TabEditState(content: "other", originalContent: "other"), for: second)
try "before event".write(to: first, atomically: true, encoding: .utf8)
expect(sync.saveTab(at: sync.findTab(with: first)!, content: "base"), "saving clean stale tab adopts external content without a conflict prompt")
expect(sync.getCachedContent(for: first) == "before event", "clean save cannot overwrite newer external content")
try "external 1".write(to: first, atomically: true, encoding: .utf8)
waitFor("inactive tab receives atomic external replacement") { sync.getCachedContent(for: first) == "external 1" }
let stamp = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as! Date
let inPlace = try FileHandle(forWritingTo: first)
try inPlace.write(contentsOf: Data("external 2".utf8))
try inPlace.close()
try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: first.path)
waitFor("same-size in-place write with preserved timestamp is detected") { sync.getCachedContent(for: first) == "external 2" }
sync.setCachedContent("local draft", for: first)
try "external 3".write(to: first, atomically: true, encoding: .utf8)
waitFor("competing external edit records silent conflict") { sync.diskState(for: first) == .conflict }
expect(sync.getCachedContent(for: first) == "local draft" && sync.getEditState(for: first)?.originalContent == "external 2", "conflict preserves both draft and original base")
expect(!sync.saveTab(at: sync.findTab(with: first)!, content: "local draft"), "automatic save refuses conflict without a dialog")
expect(try! String(contentsOf: first, encoding: .utf8) == "external 3", "external file is never overwritten on conflict")
try "local draft".write(to: first, atomically: true, encoding: .utf8)
waitFor("matching external and local edits clear conflict automatically") { sync.diskState(for: first) == .current && !sync.isModified(url: first) }
sync.setCachedContent("keep this", for: first)
try "new external".write(to: first, atomically: true, encoding: .utf8)
waitFor("second atomic replacement reconnects file watch") { sync.diskState(for: first) == .conflict }
let copy = syncProject.appendingPathComponent("copy.md")
do { try sync.saveConflictCopy(from: first, to: first); fatalError("overwrote source") } catch {}
do { try sync.saveConflictCopy(from: first, to: second); fatalError("overwrote destination") } catch {}
expect(sync.getCachedContent(for: first) == "keep this", "failed copy preserves draft")
let firstID = sync.tabs[sync.findTab(with: first)!].id
try sync.saveConflictCopy(from: first, to: copy)
expect(sync.tabs[sync.findTab(with: copy)!].id == firstID && !sync.isModified(url: copy), "successful copy relocates same tab and marks saved")
expect(try! String(contentsOf: first, encoding: .utf8) == "new external", "save copy preserves external original")
expect(try! String(contentsOf: copy, encoding: .utf8) == "keep this", "save copy contains local draft")
try FileManager.default.removeItem(at: second)
waitFor("external deletion marks tab missing") { sync.diskState(for: second) == .missing }
expect(sync.getCachedContent(for: second) == "other" && !sync.tabs[sync.findTab(with: second)!].fileExists, "deleted clean document retains editor contents and missing title state")
expect(!sync.saveTab(at: sync.findTab(with: second)!, content: "other"), "save never recreates deleted source")
sync.saveSession(to: syncProject)
let recoveredMissing = EditorTabManager(recoveryDirectory: base.appendingPathComponent("sync-recovery"))
recoveredMissing.restoreSession(from: syncProject)
expect(recoveredMissing.getCachedContent(for: second) == "other", "deleted clean buffer survives unexpected restart")
_ = recoveredMissing.closeAllTabs(force: true)
NSAlert.responses = [.alertThirdButtonReturn]
sync.closeTab(at: sync.findTab(with: second)!)
expect(sync.findTab(with: second) == nil && NSAlert.responses.count == 1, "closing deleted document discards without prompting")
sync.setCachedContent("discard conflict", for: copy)
try "external copy".write(to: copy, atomically: true, encoding: .utf8)
// No run-loop wait: close must detect an event not yet delivered by its watcher.
sync.closeTab(at: sync.findTab(with: copy)!)
expect(sync.tabs.isEmpty && NSAlert.responses.count == 1, "close detects racing external change and silently discards")
sync.restoreSession(from: syncProject)
expect(sync.tabs.isEmpty, "explicitly closed conflicts do not resurrect from recovery")
NSAlert.responses = []
let unreadTab = syncProject.appendingPathComponent("not-yet-loaded.md")
try DocumentFileStore.create("unloaded", at: unreadTab)
sync.openFile(FileSystemItem(url: unreadTab, isDirectory: false))
try FileManager.default.removeItem(at: unreadTab)
waitFor("unloaded restored-style tab still tracks deletion") { sync.diskState(for: unreadTab) == .missing }
sync.closeTab(at: sync.findTab(with: unreadTab)!)

// Isolated architecture integration: participants and events share one scoped coordinator.
let bus = WorkspaceFileEvents()
let files = WorkspaceFileCoordinator(events: bus)
let ownedProject = base.appendingPathComponent("Owned.weaveproj")
try FileManager.default.createDirectory(at: ownedProject, withIntermediateDirectories: true)
let owned = EditorTabManager(recoveryDirectory: base.appendingPathComponent("owned-recovery"), files: files)
owned.restoreSession(from: ownedProject)
let oldPath = ownedProject.appendingPathComponent("old.md")
try files.documents.create("base", at: oldPath)
owned.openFile(FileSystemItem(url: oldPath, isDirectory: false))
owned.setEditState(TabEditState(content: "local draft", originalContent: "base"), for: oldPath)
let identity = owned.tabs[0].id
var commits: [WorkspaceFileEvent] = []
let listener = bus.observe { commits.append($0) }
let movedPath = ownedProject.appendingPathComponent("new.md")
try files.move(from: oldPath, to: movedPath)
expect(owned.tabs[0].url == movedPath && owned.tabs[0].id == identity, "committed move event updates tab identity and path")
expect(owned.getCachedContent(for: movedPath) == "local draft", "move event preserves unsaved buffer")
let occupied = ownedProject.appendingPathComponent("occupied.md")
try files.documents.create("occupied", at: occupied)
let commitCount = commits.count
do { try files.move(from: movedPath, to: occupied); fatalError("must not overwrite target") } catch {}
expect(commits.count == commitCount && owned.tabs[0].url == movedPath, "failed move publishes no commit and leaves tab ownership unchanged")
NSAlert.responses = [.alertThirdButtonReturn]
expect(try! !files.trash(movedPath), "document participant vetoes deletion before disk mutation")
expect(FileManager.default.fileExists(atPath: movedPath.path) && owned.tabs.count == 1, "cancelled delete preserves file and tab")
let beforeFailedSave = commits.count
do { try files.documents.save("overwrite", at: movedPath, expected: "stale"); fatalError("must reject stale write") } catch {}
expect(commits.count == beforeFailedSave, "failed save publishes no success event")
owned.setCachedContent("base", for: movedPath)
try files.documents.save("changed through repository", at: movedPath, expected: "base")
waitFor("repository save event refreshes the same editor state") { owned.getCachedContent(for: movedPath) == "changed through repository" }
expect(DocumentReconciliation.decide(base: "a", draft: "a", disk: "b") == .adoptDisk, "clean document adopts disk by common policy")
expect(DocumentReconciliation.decide(base: "a", draft: "b", disk: "c") == .conflict, "divergent versions conflict by common policy")
expect(DocumentReconciliation.decide(base: "a", draft: "b", disk: "b") == .adoptDisk, "converged versions become saved by common policy")
let ticket = DocumentReadIdentity(requestID: UUID(), documentID: identity, base: "a")
expect(!ticket.matches(requestID: UUID(), documentID: identity, base: "a"), "read ticket rejects older request generation")
expect(!ticket.matches(requestID: ticket.requestID, documentID: UUID(), base: "a"), "read ticket rejects replacement document")
expect(!ticket.matches(requestID: ticket.requestID, documentID: identity, base: "b"), "read ticket rejects changed save baseline")
bus.remove(listener)
_ = owned.closeAllTabs(force: true)

final class DelayedDocumentRepository: WorkspaceDocumentRepository {
    var pending: [CheckedContinuation<String, Error>] = []
    func read(_ url: URL) throws -> String { "base" }
    func readSnapshot(_ url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func save(_ content: String, at url: URL, expected: String) throws {}
    func create(_ content: String, at url: URL) throws {}
}
let delayed = DelayedDocumentRepository()
let reader = DocumentObservationController(repository: delayed, events: WorkspaceFileEvents())
let readURL = URL(fileURLWithPath: "/fixture.md")
let readDocumentID = UUID()
var readBase = "base"
var accepted: [String] = []
reader.identity = { _ in (readDocumentID, readBase) }
reader.receive = { _, result in if case .success(let text) = result { accepted.append(text) } }
reader.requestRead(readURL)
waitFor("first asynchronous read started") { delayed.pending.count == 1 }
reader.requestRead(readURL)
waitFor("replacement asynchronous read started") { delayed.pending.count == 2 }
delayed.pending[1].resume(returning: "new")
waitFor("latest asynchronous result accepted") { accepted == ["new"] }
delayed.pending[0].resume(returning: "obsolete")
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
expect(accepted == ["new"], "late cancelled read cannot overwrite newer content")
reader.requestRead(readURL)
waitFor("baseline test read started") { delayed.pending.count == 3 }
readBase = "saved during read"
delayed.pending[2].resume(returning: "pre-save snapshot")
waitFor("changed baseline triggers fresh read") { delayed.pending.count == 4 }
expect(accepted == ["new"], "pre-save snapshot is never published")
delayed.pending[3].resume(returning: "post-save snapshot")
waitFor("fresh baseline result accepted") { accepted.last == "post-save snapshot" }
reader.stop()

let mergeFile = project.appendingPathComponent("concurrent.md")
let mergeBase = "first\nsecond\nthird"
try DocumentFileStore.create(mergeBase, at: mergeFile)
manager.openFile(FileSystemItem(url: mergeFile, isDirectory: false))
manager.setEditState(TabEditState(content: "human\nsecond\nthird", originalContent: mergeBase), for: mergeFile)
try Data("first\nsecond\nexternal".utf8).write(to: mergeFile)
expect(manager.saveTab(at: manager.selectedTabIndex, content: "human\nsecond\nthird"), "save rebases independent disk change")
expect(try! String(contentsOf: mergeFile, encoding: .utf8) == "human\nsecond\nexternal", "saved disk contains both edits")
expect(manager.getCachedContent(for: mergeFile) == "human\nsecond\nexternal" && !manager.isModified(url: mergeFile), "save updates cache and base to merged text")
manager.setEditState(TabEditState(content: "human\nunsaved\nexternal", originalContent: "human\nsecond\nexternal"), for: mergeFile)
manager.receiveDiskContent("human\nsecond\nlatest", for: mergeFile)
expect(manager.getCachedContent(for: mergeFile) == "human\nunsaved\nlatest", "external refresh merges into dirty draft")
expect(manager.getEditState(for: mergeFile)?.originalContent == "human\nsecond\nlatest" && manager.isModified(url: mergeFile), "refresh retains unsaved ownership over latest disk base")
manager.receiveDiskContent("human\ncompeting\nlatest", for: mergeFile)
expect(manager.diskState(for: mergeFile) == .conflict && manager.getCachedContent(for: mergeFile) == "human\nunsaved\nlatest", "overlap retains draft and marks conflict")
print("ALL STORAGE REGRESSIONS PASSED")


'''
with tempfile.TemporaryDirectory(prefix="textlinkeditor-storage-tests-") as work:
    work = Path(work)
    (work / "main.swift").write_text(swift)
    subprocess.run(["xcrun", "swiftc", str(root / "TextlinkEditor/Services/FileSystem/DocumentFileStore.swift"), *[str(p) for p in (root / "TextlinkEditor/Services/FileSystem/Workspace").glob("*.swift")],
                    str(root / "TextlinkEditor/Services/Editor/EditorTabManager.swift"), *[str(p) for p in (root / "TextlinkEditor/Services/Editor/Session").glob("*.swift")], str(root / "TextlinkEditor/Services/Versions/VersionHistoryStore.swift"), str(root / "TextlinkEditor/Services/Writing/WritingWorkspaceStore.swift"), str(work / "main.swift"),
                    "-o", str(work / "regression")], check=True)
    subprocess.run([str(work / "regression")], check=True)
