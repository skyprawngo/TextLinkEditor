import Foundation

struct ProjectSidebarLayout: Codable, Equatable {
    var changesHeight: Double = 220
    var graphHeight: Double = 160

    private static func file(in project: URL) -> URL {
        project.appendingPathComponent(".\(project.deletingPathExtension().lastPathComponent).weavedata", isDirectory: true)
            .appendingPathComponent("sidebar-layout.json")
    }

    static func load(from project: URL) throws -> Self {
        let url = file(in: project)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        var value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        value.changesHeight = min(2000, max(140, value.changesHeight))
        value.graphHeight = min(2000, max(60, value.graphHeight))
        return value
    }

    func save(to project: URL) throws {
        let url = Self.file(in: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
