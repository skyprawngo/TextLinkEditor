import SwiftUI

struct ProjectSearchHit: Identifiable, Sendable {
    var id: String { url.path + ":" + String(line) }
    let url: URL
    let line: Int
    let preview: String
}

struct ProjectSearchView: View {
    let projectURL: URL?
    @Binding var query: String
    @Environment(\.dismiss) private var dismiss
    @State private var results: [ProjectSearchHit] = []
    @State private var searching = false
    @State private var showingReplace = false

    var body: some View {
        VStack(alignment: .leading) {
            SheetHeader(title: L10n.get("search.project")) { dismiss() }
                .padding([.horizontal, .top], 20)
            HStack {
                TextField(L10n.get("search.project"), text: $query).textFieldStyle(.roundedBorder)
                if searching { ProgressView().controlSize(.small) }
                Button(L10n.get("projectReplace.title")) { showingReplace = true }.disabled(projectURL == nil)
            }.padding()
            List(results) { hit in
                Button {
                    EditorTabManager.shared.openFile(FileSystemItem(url: hit.url, isDirectory: false))
                    AppCommands.shared.searchResultLine = hit.line - 1
                    AppCommands.shared.searchInDocument = query
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.url.lastPathComponent + ":" + String(hit.line)).font(.headline)
                        Text(hit.preview).lineLimit(2).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            Text(L10n.get("search.limit")).font(.caption).foregroundStyle(.secondary).padding()
        }
        .frame(minWidth: 600, minHeight: 400)
        .sheet(isPresented: $showingReplace) {
            if let projectURL { ProjectReplaceView(projectURL: projectURL, initialQuery: query) }
        }
        .task(id: query) {
            guard let projectURL, !query.isEmpty else { results = []; return }
            searching = true
            let query = query
            EditorTabManager.shared.flushEditor()
            let cached = Dictionary(uniqueKeysWithValues: EditorTabManager.shared.tabs.compactMap { tab -> (URL, String)? in
                // Restored clean tabs may only contain a cursor placeholder, not loaded text.
                guard EditorTabManager.shared.isModified(url: tab.url) else { return nil }
                return EditorTabManager.shared.getCachedContent(for: tab.url).map { (tab.url, $0) }
            })
            let job = Task.detached(priority: .userInitiated) {
                var hits: [ProjectSearchHit] = []
                let enumerator = FileManager.default.enumerator(at: projectURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
                while let url = enumerator?.nextObject() as? URL {
                    if Task.isCancelled || hits.count >= 200 { break }
                    guard ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()),
                          let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5_000_000,
                          let text = cached[url] ?? (try? String(contentsOf: url, encoding: .utf8)) else { continue }
                    for (line, content) in text.components(separatedBy: "\n").enumerated() {
                        if hits.count >= 200 || Task.isCancelled { break }
                        if content.localizedCaseInsensitiveContains(query) {
                            hits.append(ProjectSearchHit(url: url, line: line + 1, preview: String(content.prefix(240))))
                        }
                    }
                }
                return hits
            }
            let found = await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
            guard !Task.isCancelled else { return }
            results = found
            searching = false
        }
    }
}
