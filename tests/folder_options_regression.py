#!/usr/bin/env python3
"""Exercise real folder appearance storage and FileSystemManager using temporary projects."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
import Foundation
import AppKit
import SwiftUI

enum L10n {
    static var strings: [String: String] = [:]
    static func get(_ key: String) -> String { strings[key] ?? key }
    enum editor { static let untitled = "Untitled" }
    enum common {
        static let confirm = "OK", cancel = "Cancel", save = "Save", delete = "Delete"
    }
}
struct UserSettings {
    static let shared = UserSettings()
    let editorFontName = "system"
    let editorFontSize: CGFloat = 14, editorLineSpacing: CGFloat = 1
}
enum ProjectManager { static let dataFolderExtension = "weavedata" }
extension NSAlert {
    func beginSheetModalWithArrowNavigation(for window: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        beginSheetModal(for: window, completionHandler: completionHandler)
    }
}
'''
FILES = [
    'TextlinkEditor/Models/FileSystemItem.swift',
    'TextlinkEditor/Services/FileSystem/DocumentFileStore.swift',
    'TextlinkEditor/Services/FileSystem/FolderAppearanceStore.swift',
    'TextlinkEditor/Services/FileSystem/FileSystemManager.swift',
    'TextlinkEditor/Services/FileSystem/FileSystemDialogs.swift',
    'TextlinkEditor/Services/FileSystem/SidebarFileDrop.swift',
]
FILES += ['TextlinkEditor/Services/Editor/EditorTabManager.swift', 'TextlinkEditor/Services/Versions/VersionHistoryStore.swift', 'TextlinkEditor/Services/Writing/WritingWorkspaceStore.swift']
FILES += [str(p.relative_to(ROOT)) for p in (ROOT / 'TextlinkEditor/Services/Editor/Session').glob('*.swift')]
FILES += [str(p.relative_to(ROOT)) for p in (ROOT / 'TextlinkEditor/Services/FileSystem/Workspace').glob('*.swift')]
SOURCE = SUPPORT + '\n'.join((ROOT / path).read_text() for path in FILES)
HARNESS = r'''
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
    print("PASS " + message)
}
let fm = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let project = base.appendingPathComponent("Novel.weaveproj")
try fm.createDirectory(at: project, withIntermediateDirectories: true)
let store = FolderAppearanceStore(projectURL: project)
expect(try! store.load().isEmpty, "old projects need no migration")
let manager = FileSystemManager.shared
manager.initializeProject(at: project)
let root = manager.projectRoot!
let folder = manager.createFolder(named: "세계관", in: root)!
let nested = manager.createFolder(named: "Nested", in: folder)!
try manager.setFolderIcon(.star, for: folder)
try manager.setFolderIcon(.book, for: nested)
expect(folder.iconName == "star", "custom icon overrides section icon immediately")
folder.isExpanded = true
expect(folder.iconName == "star", "expansion retains custom icon")
manager.refreshProject()
expect(manager.findItem(by: folder.url)?.iconName == "star", "refresh retains override")
manager.closeProject()
manager.initializeProject(at: project)
let reopened = manager.projectRoot!.children!.first!
expect(reopened.iconName == "star", "reopening loads saved icon")
expect(manager.rename(reopened, to: "Renamed"), "folder rename succeeds")
let renamed = manager.projectRoot!.children!.first!
expect(renamed.iconName == "star", "rename retains icon")
manager.loadChildren(of: renamed)
expect(renamed.children!.first!.iconName == "book", "rename carries descendant metadata")
let destination = manager.createFolder(named: "Destination", in: manager.projectRoot!)!
expect(manager.move(renamed, to: destination), "folder move succeeds")
let moved = destination.children!.first!
expect(moved.iconName == "star", "move retains icon")
expect(manager.copy(moved, to: manager.projectRoot!), "folder copy succeeds")
let copy = manager.projectRoot!.children!.first { $0.name == "Renamed" }!
expect(copy.iconName == "star", "copy carries appearance")
try manager.setFolderIcon(nil, for: copy)
expect(copy.iconName == "folder", "default clears custom icon")
expect(moved.iconName == "star", "reset does not alter source folder")
let section = manager.createFolder(named: "설정", in: manager.projectRoot!)!
try manager.setFolderIcon(.heart, for: section)
try manager.setFolderIcon(nil, for: section)
expect(section.iconName == "globe.asia.australia", "reset restores built-in section icon")
let other = base.appendingPathComponent("Other.weaveproj")
try fm.createDirectory(at: other, withIntermediateDirectories: true)
manager.initializeProject(at: other)
do { try manager.setFolderIcon(.flag, for: moved); fatalError("accepted stale project folder") } catch {}
expect(try! FolderAppearanceStore(projectURL: other).load().isEmpty, "project switch isolates metadata")
manager.initializeProject(at: project)
let current = manager.projectRoot!.children!.first { $0.name == "Renamed" }!
let metadata = project.appendingPathComponent(".Novel.weavedata/folder-icons.json")
let saved = try Data(contentsOf: metadata)
try Data("invalid".utf8).write(to: metadata)
do { try manager.setFolderIcon(.film, for: current); fatalError("overwrote corrupt metadata") } catch {}
expect(try! String(contentsOf: metadata, encoding: .utf8) == "invalid", "invalid metadata is preserved on save failure")
expect(current.customFolderIcon == nil, "failed save does not change visible icon")
try saved.write(to: metadata)
try store.remove(for: moved.url)
expect(try! store.load().keys.allSatisfy { !$0.hasPrefix("Destination/Renamed") }, "removal clears descendant overrides")
expect(try! store.load().keys.contains("Renamed/Nested"), "removal preserves copied subtree")
for icon in FolderIcon.allCases {
    expect(NSImage(systemSymbolName: icon.rawValue, accessibilityDescription: nil) != nil, "symbol exists: " + icon.rawValue)
}
let editor = EditorTabManager(recoveryDirectory: base.appendingPathComponent("Recovery"))
editor.restoreSession(from: project)
let manuscript = manager.createFile(named: "draft.md", in: manager.projectRoot!, content: "baseline")!
editor.openFile(manuscript)
editor.setEditState(TabEditState(content: "unsaved", originalContent: "baseline"), for: manuscript.url)
let tabID = editor.tabs[0].id
expect(manager.rename(manuscript, to: "renamed-draft.md"), "sidebar rename command succeeds")
let renamedDocument = project.appendingPathComponent("renamed-draft.md")
expect(editor.tabs[0].id == tabID && editor.tabs[0].url == renamedDocument, "sidebar and tab use same committed path")
expect(editor.getCachedContent(for: renamedDocument) == "unsaved", "sidebar rename retains live editor draft")
let projectedFile = manager.findItem(by: renamedDocument)!
editor.openFile(projectedFile)
expect(editor.tabs.count == 1 && editor.selectedTab?.id == tabID, "sidebar path alias selects existing tab instead of duplicating it")
expect(editor.getCachedContent(for: projectedFile.url) == "unsaved", "path alias reads the same editor buffer")
expect(manager.findItem(by: renamedDocument) != nil && manager.findItem(by: manuscript.url) == nil, "sidebar replaces old path with renamed path")
editor.setCachedContent("baseline", for: renamedDocument)
try DocumentFileStore.save("external-style write", at: renamedDocument, expected: "baseline")
let deadline = Date().addingTimeInterval(5)
while editor.getCachedContent(for: renamedDocument) != "external-style write", Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
expect(editor.getCachedContent(for: renamedDocument) == "external-style write", "shared repository event updates renamed document")
_ = editor.closeAllTabs(force: true)
let deletedFolder = project.appendingPathComponent("삭제폴더")
try fm.createDirectory(at: deletedFolder, withIntermediateDirectories: true)
for name in ["a.md", "b.md", "c.md"] {
    let url = deletedFolder.appendingPathComponent(name)
    try "text".write(to: url, atomically: true, encoding: .utf8)
    editor.openFile(FileSystemItem(url: url, isDirectory: false))
}
editor.openFile(FileSystemItem(url: renamedDocument, isDirectory: false))
let survivingID = editor.selectedTab!.id
var deletionNotifications = 0
var selectedDeletedDocument = false
let deletionObserver = NotificationCenter.default.addObserver(forName: .editorTabsDidChange, object: nil, queue: nil) { _ in
    deletionNotifications += 1
    if let url = editor.selectedTab?.url, DocumentFileStore.contains(url, in: deletedFolder) { selectedDeletedDocument = true }
}
// Use a recoverable move to model a successful folder trash operation.
try fm.moveItem(at: deletedFolder, to: base.appendingPathComponent("DeletedFolder"))
editor.closeTabsUnder(folderURL: URL(fileURLWithPath: deletedFolder.path.decomposedStringWithCanonicalMapping))
expect(editor.tabs.count == 1 && editor.selectedTab?.id == survivingID, "folder deletion closes all descendants with normalized paths and preserves unrelated selection")
expect(deletionNotifications == 1 && !selectedDeletedDocument, "folder deletion publishes only the final surviving selection")
editor.closeTabsUnder(folderURL: deletedFolder)
expect(deletionNotifications == 1, "duplicate deletion callback is a no-op")
NotificationCenter.default.removeObserver(deletionObserver)
_ = editor.closeAllTabs(force: true)
let watchedFolder = manager.createFolder(named: "WatchedDeletion", in: manager.projectRoot!)!
let watchedChild = manager.createFolder(named: "Nested", in: watchedFolder)!
manager.loadChildren(of: watchedFolder)
manager.loadChildren(of: watchedChild)
manager.operationError = nil
expect(manager.delete(watchedFolder), "watched folder deletion succeeds")
let deletionDeadline = Date().addingTimeInterval(0.5)
while Date() < deletionDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
expect(manager.operationError == nil, "deleted folder watchers do not report a read failure")
let dropRoot = manager.projectRoot!
let finderSource = base.appendingPathComponent("Finder 한글 file.md")
try "external contents".write(to: finderSource, atomically: true, encoding: .utf8)
func provider(_ url: URL, type: String = "public.file-url") -> NSItemProvider {
    let result = NSItemProvider()
    result.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
        completion(Data(url.absoluteString.utf8), nil)
        return nil
    }
    return result
}
func drop(_ providers: [NSItemProvider], into target: FileSystemItem) {
    var finished = false
    expect(SidebarFileDrop.accept(providers, destination: target, manager: manager,
        find: { manager.findItem(by: $0) }, move: { manager.move($0, to: target) }, completion: { finished = true }), "drop accepts supported providers")
    let deadline = Date().addingTimeInterval(5)
    while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    expect(finished, "drop completes asynchronously")
}
drop([provider(finderSource), provider(finderSource)], into: dropRoot)
expect(fm.fileExists(atPath: finderSource.path), "Finder copy preserves original")
expect(try! String(contentsOf: project.appendingPathComponent("Finder 한글 file.md"), encoding: .utf8) == "external contents", "Finder URL copies into project root")
expect(fm.fileExists(atPath: project.appendingPathComponent("Finder 한글 file 1.md").path), "multiple providers resolve duplicate names without overwriting")
let dropFolder = manager.createFolder(named: "DropFolder", in: dropRoot)!
drop([provider(finderSource)], into: dropFolder)
expect(fm.fileExists(atPath: dropFolder.url.appendingPathComponent(finderSource.lastPathComponent).path), "Finder drop targets nested folder")
let internalFile = project.appendingPathComponent("Finder 한글 file 1.md")
drop([provider(internalFile, type: "public.utf8-plain-text")], into: dropFolder)
expect(!fm.fileExists(atPath: internalFile.path), "internal string drag retains move behavior")
expect(SidebarFileDrop.fileURL("https://example.com" as NSString) == nil, "non-file URLs are rejected")
manager.closeProject()
print("ALL FOLDER OPTIONS REGRESSIONS PASSED")
'''

if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='folder-options-') as temp:
        directory = Path(temp)
        fixture = directory / 'main.swift'
        fixture.write_text(SOURCE + HARNESS)
        executable = directory / 'regression'
        subprocess.run(['swiftc', str(fixture), '-o', str(executable)], check=True)
        subprocess.run([str(executable), str(directory)], check=True)
