import Foundation

enum SidebarPathCopy {
    static func path(for url: URL, relativeTo root: URL?) -> String? {
        let path = url.standardizedFileURL.path
        guard let root else { return path }
        let base = root.standardizedFileURL.path
        if path == base { return "." }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
