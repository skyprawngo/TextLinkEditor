import Foundation

@main struct SidebarLayoutRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second.weaveproj")
        let initial = try ProjectSidebarLayout.load(from: first)
        precondition(initial == ProjectSidebarLayout())
        var layout = initial
        layout.changesHeight = 310
        layout.graphHeight = 190
        try layout.save(to: first)
        let restored = try ProjectSidebarLayout.load(from: first)
        precondition(restored == layout)
        let other = try ProjectSidebarLayout.load(from: second)
        precondition(other == initial, "project sizes must remain independent")
        try other.save(to: second)
        precondition(FileManager.default.fileExists(atPath: second.appendingPathComponent(".Second.weavedata/sidebar-layout.json").path))
        layout.changesHeight = -10
        layout.graphHeight = 5000
        try layout.save(to: first)
        let bounded = try ProjectSidebarLayout.load(from: first)
        precondition(bounded.changesHeight == 140 && bounded.graphHeight == 2000)
        print("PASS defaults, disk restoration, project isolation, metadata path and size bounds")
    }
}
