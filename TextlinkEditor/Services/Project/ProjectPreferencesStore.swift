import Foundation

/// Persists recent projects and security-scoped bookmarks using the existing keys.
/// Inject UserDefaults for isolated storage tests; project transitions remain in ProjectManager.
final class ProjectPreferencesStore {
    private let defaults: UserDefaults
    private let recentProjectsKey = "recentProjects"
    private let bookmarkDataKey = "projectBookmarks"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// 폴더에 대한 Security-Scoped Bookmark 저장
    func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            var bookmarks = defaults.dictionary(forKey: bookmarkDataKey) as? [String: Data] ?? [:]
            bookmarks[url.path] = bookmarkData
            defaults.set(bookmarks, forKey: bookmarkDataKey)
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }

    /// 저장된 Bookmark로 폴더 접근 권한 복원
    func restoreAccess(to url: URL) -> Bool {
        guard let bookmarks = defaults.dictionary(forKey: bookmarkDataKey) as? [String: Data],
              let bookmarkData = bookmarks[url.path] else {
            return false
        }

        do {
            var isStale = false
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                // Bookmark이 오래된 경우 새로 저장
                saveBookmark(for: resolvedURL)
            }

            return resolvedURL.startAccessingSecurityScopedResource()
        } catch {
            print("Failed to restore access: \(error)")
            return false
        }
    }

    /// Security-Scoped Resource 접근 종료
    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    // MARK: - Recent Projects

    func loadRecentProjects() -> [Project] {
        guard let data = defaults.data(forKey: recentProjectsKey),
              let projects = try? JSONDecoder().decode([Project].self, from: data) else { return [] }
        return projects
    }

    func saveRecentProjects(_ projects: [Project]) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: recentProjectsKey)
    }

    /// 존재하지 않는 프로젝트의 북마크 데이터 제거
    func removeBookmarks(for paths: [String]) {
        guard var bookmarks = defaults.dictionary(forKey: bookmarkDataKey) as? [String: Data] else {
            return
        }

        for path in paths {
            bookmarks.removeValue(forKey: path)
        }

        defaults.set(bookmarks, forKey: bookmarkDataKey)
    }

}
