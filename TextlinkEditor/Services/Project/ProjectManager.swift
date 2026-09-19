//
//  ProjectManager.swift
//  TextlinkEditor
//
//  프로젝트 관리 서비스
//

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@Observable
final class ProjectManager {
    static let shared = ProjectManager()

    var recentProjects: [Project] = []
    var currentProject: Project?

    private let preferences = ProjectPreferencesStore()
    private let maxRecentProjects = 10

    /// Open panel delegate (강한 참조 유지)
    private var openPanelDelegate: ProjectFolderPanelDelegate?

    /// 프로젝트 데이터 숨김 폴더 확장자 (.weavedata)
    static let dataFolderExtension = "weavedata"
    /// 프로젝트 메타데이터 파일명
    private let projectMetadataFile = "project.json"

    /// 프로젝트 폴더에서 숨김 데이터 폴더 경로 생성
    /// - Parameter projectFolderURL: 프로젝트 폴더 URL
    /// - Returns: 프로젝트 내부의 숨김 데이터 폴더 URL
    private func dataFolderURL(for projectFolderURL: URL) -> URL {
        let projectName = projectFolderURL.deletingPathExtension().lastPathComponent
        let dataFolderName = ".\(projectName).\(Self.dataFolderExtension)"
        return projectFolderURL.appendingPathComponent(dataFolderName)
    }

    /// 프로젝트 메타데이터 파일 경로
    private func metadataURL(for projectFolderURL: URL) -> URL {
        return dataFolderURL(for: projectFolderURL).appendingPathComponent(projectMetadataFile)
    }

    /// 기본 저장 위치 (PermissionManager에서 승인된 폴더 또는 사용자 Documents 폴더)
    var defaultSaveDirectory: URL {
        // PermissionManager에서 승인된 Documents 폴더 사용
        if let grantedURL = PermissionManager.shared.getBookmarkedURL(for: .documentsAccess) {
            return grantedURL
        }
        // 폴백: 기본 Documents 경로 (샌드박스 내)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    }

    private init() {
        loadRecentProjects()
        validateRecentProjects()
    }

    // MARK: - Security-Scoped Bookmarks

    private func saveBookmark(for url: URL) { preferences.saveBookmark(for: url) }
    private func restoreAccess(to url: URL) -> Bool { preferences.restoreAccess(to: url) }
    func stopAccessing(_ url: URL) { preferences.stopAccessing(url) }

    // MARK: - Recent Projects

    private func loadRecentProjects() { recentProjects = preferences.loadRecentProjects() }
    private func saveRecentProjects() { preferences.saveRecentProjects(recentProjects) }

    private func validateRecentProjects() {
        // Offline volumes and temporary permission failures must not erase bookmarks.
        recentProjects.removeAll { $0.path == nil }
    }

    private func removeBookmarks(for paths: [String]) { preferences.removeBookmarks(for: paths) }

    // MARK: - Project Operations

    /// 새 프로젝트 생성 (일반 폴더, 확장자 자동 추가 없음)
    /// - Parameters:
    ///   - name: 프로젝트 폴더 이름
    ///   - directoryURL: 저장할 디렉토리
    ///   - options: 포함할 기본 폴더 (기본값은 전체 포함)
    /// - Returns: 생성된 프로젝트
    func createProject(name: String, at directoryURL: URL, options: ProjectCreationOptions = .init()) -> Project? {
        do { try DocumentFileStore.validateName(name) }
        catch { presentError(error); return nil }
        let projectFolderURL = directoryURL.appendingPathComponent(name, isDirectory: true)
        let project = Project(name: name, path: projectFolderURL)

        // 숨김 데이터 폴더 및 메타데이터 파일 경로
        let dataFolder = dataFolderURL(for: projectFolderURL)
        let metadata = metadataURL(for: projectFolderURL)

        do {
            // 프로젝트 폴더 생성
            guard !FileManager.default.fileExists(atPath: projectFolderURL.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            guard EditorTabManager.shared.prepareToClose(EditorTabManager.shared.tabs) else { return nil }
            if let old = currentProject?.path { EditorTabManager.shared.saveSession(to: old, omittingApprovedDiscards: true) }
            try FileManager.default.createDirectory(at: projectFolderURL, withIntermediateDirectories: false)

            // 숨김 데이터 폴더 생성 (.abc.weavedata)
            try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)

            // 선택한 기본 폴더만 생성 (현재 언어에 맞는 이름으로)
            for section in options.orderedSections {
                let sectionFolderURL = projectFolderURL.appendingPathComponent(section.localizedFolderName)
                try FileManager.default.createDirectory(at: sectionFolderURL, withIntermediateDirectories: true)
            }

            // 메타데이터 파일 저장 (숨김 폴더 내부)
            let data = try JSONEncoder().encode(project)
            try data.write(to: metadata)

            // Security-Scoped Bookmark 저장 (앱 재시작 후에도 접근 가능하도록)
            saveBookmark(for: projectFolderURL)

            addToRecentProjects(project)
            if let old = currentProject?.path { stopAccessing(old) }
            currentProject = project
            UserSettings.shared.setLastOpenedProject(projectFolderURL)
            EditorTabManager.shared.restoreSession(from: projectFolderURL)
            return project
        } catch {
            presentError(error)
            return nil
        }
    }

    /// 일반 폴더에서 프로젝트 열기
    func openProjectFromFile(at url: URL) -> Project? {
        if currentProject?.path == url { return currentProject }
        let access = restoreAccess(to: url)
        do {
            let metadata = metadataURL(for: url)
            var project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: metadata))
            project.path = url
            project.lastOpenedAt = Date()
            // Validate the destination before asking to leave the old workspace.
            guard EditorTabManager.shared.prepareToClose(EditorTabManager.shared.tabs) else {
                if access { stopAccessing(url) }
                return nil
            }
            if let old = currentProject?.path {
                EditorTabManager.shared.saveSession(to: old, omittingApprovedDiscards: true)
                stopAccessing(old)
            }
            // Read-only projects remain readable; last-opened bookkeeping is best effort.
            try? JSONEncoder().encode(project).write(to: metadata, options: .atomic)
            saveBookmark(for: url)
            addToRecentProjects(project)
            currentProject = project
            UserSettings.shared.setLastOpenedProject(url)
            EditorTabManager.shared.restoreSession(from: url)
            return project
        } catch {
            removeMissingRecentProject(at: url)
            if access { stopAccessing(url) }
            presentError(error)
            return nil
        }
    }

    /// Only a confirmed missing directory invalidates a recent path. Metadata or
    /// permission failures must not discard a project that still exists.
    private func removeMissingRecentProject(at url: URL) {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return
        } catch {
            let failure = error as NSError
            guard failure.domain == NSCocoaErrorDomain,
                  failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError else { return }
        }
        let path = url.standardizedFileURL.path
        let removed = recentProjects.compactMap(\.path).filter { $0.standardizedFileURL.path == path }
        recentProjects.removeAll { $0.path?.standardizedFileURL.path == path }
        saveRecentProjects()
        removeBookmarks(for: Array(Set(removed.map(\.path) + [url.path])))
        UserSettings.shared.clearLastOpenedProject(ifMatching: url)
    }

    @discardableResult
    func openProject(_ project: Project) -> Bool {
        guard let url = project.path else { return false }
        return openProjectFromFile(at: url) != nil
    }

    func closeProject() {
        let tabs = EditorTabManager.shared
        guard tabs.prepareToClose(tabs.tabs) else { return }
        if let path = currentProject?.path {
            tabs.saveSession(to: path, omittingApprovedDiscards: true)
            stopAccessing(path)
        }
        tabs.closeAllTabs(force: true)
        currentProject = nil
    }

    func deleteProject(_ project: Project) {
        recentProjects.removeAll { $0.id == project.id }
        saveRecentProjects()

        // Removing a recent item does not close its open workspace.
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.get("storage.operationFailed")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func addToRecentProjects(_ project: Project) {
        // 이미 존재하면 제거
        recentProjects.removeAll { $0.id == project.id }

        // 맨 앞에 추가
        recentProjects.insert(project, at: 0)

        // 최대 개수 제한
        if recentProjects.count > maxRecentProjects {
            recentProjects = Array(recentProjects.prefix(maxRecentProjects))
        }

        saveRecentProjects()
    }

    // MARK: - File Dialogs

    func showSaveDirectoryPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.get("welcome.selectSaveLocation")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.get("welcome.selectFolderMessage")
        panel.prompt = L10n.get("welcome.selectFolder")
        panel.directoryURL = defaultSaveDirectory

        if panel.runModal() == .OK {
            return panel.url
        }
        return nil
    }

    func showOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.get("welcome.openProject")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = L10n.get("welcome.selectProjectFolder")
        panel.directoryURL = defaultSaveDirectory

        // 프로젝트 메타데이터로 확인하므로 폴더 확장자는 제한하지 않는다.
        // delegate를 인스턴스 프로퍼티에 저장하여 runModal() 중 메모리 해제 방지
        openPanelDelegate = ProjectFolderPanelDelegate()
        panel.delegate = openPanelDelegate

        let result = panel.runModal()
        openPanelDelegate = nil

        if result == .OK {
            return panel.url
        }
        return nil
    }

    func isProjectFolder(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let data = try? Data(contentsOf: metadataURL(for: url)) else { return false }
        return (try? JSONDecoder().decode(Project.self, from: data)) != nil
    }
}

// MARK: - Open Panel Delegate

/// 탐색은 모든 폴더를 허용하고 프로젝트 메타데이터로 선택을 검증한다.
final class ProjectFolderPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        // 디렉토리인 경우
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }

        if isDirectory.boolValue {
            return true
        }

        return false
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard ProjectManager.shared.isProjectFolder(url) else {
            throw NSError(
                domain: "ProjectManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.get("welcome.invalidProjectFolder")]
            )
        }
    }
}
