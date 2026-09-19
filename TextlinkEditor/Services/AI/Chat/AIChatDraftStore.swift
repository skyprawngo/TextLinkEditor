import Foundation

/// Local composer state, separate from sent messages and provider sessions.
/// UserDefaults caches writes and persists them without synchronous file I/O per keystroke.
final class AIChatDraftStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    private func key(_ project: URL) -> String {
        "ai.chatDrafts.v1." + project.resolvingSymlinksInPath().standardizedFileURL.absoluteString
    }
    private func drafts(_ project: URL) -> [String: String] {
        defaults.dictionary(forKey: key(project)) as? [String: String] ?? [:]
    }
    func text(project: URL?, conversation: UUID?) -> String {
        guard let project else { return "" }
        return drafts(project)[conversation?.uuidString ?? "new"] ?? ""
    }
    func save(_ text: String, project: URL?, conversation: UUID?) {
        guard let project else { return }
        var values = drafts(project)
        let id = conversation?.uuidString ?? "new"
        guard values[id] != (text.isEmpty ? nil : text) else { return }
        values[id] = text.isEmpty ? nil : text
        if values.isEmpty { defaults.removeObject(forKey: key(project)) }
        else { defaults.set(values, forKey: key(project)) }
    }
    func clear(project: URL?) {
        guard let project else { return }
        defaults.removeObject(forKey: key(project))
    }
}
