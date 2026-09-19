import AppKit
import UniformTypeIdentifiers

/// Both explorer targets use the same URL loading and file-operation boundary.
enum SidebarFileDrop {
    static let types = [UTType.fileURL.identifier, UTType.utf8PlainText.identifier]

    static func accept(_ providers: [NSItemProvider], destination: FileSystemItem,
                       manager: FileSystemManager, find: @escaping (URL) -> FileSystemItem?,
                       move: @escaping (FileSystemItem) -> Bool, completion: @escaping () -> Void) -> Bool {
        guard destination.isDirectory, let root = manager.projectRoot else { return false }
        let eligible = providers.filter { provider in types.contains { provider.hasItemConformingToTypeIdentifier($0) } }
        guard !eligible.isEmpty else { return false }
        // Consume providers in order, including multi-file Finder drags.
        func load(_ index: Int) {
            guard index < eligible.count else { completion(); return }
            let provider = eligible[index]
            let fromFinder = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            let type = fromFinder ? UTType.fileURL.identifier : UTType.utf8PlainText.identifier
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                DispatchQueue.main.async {
                    guard manager.projectRoot === root else { return }
                    if error == nil, let url = fileURL(value) {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let source = url.resolvingSymlinksInPath().standardizedFileURL.path
                        let target = destination.url.resolvingSymlinksInPath().standardizedFileURL.path
                        if source != target && !target.hasPrefix(source + "/") {
                            if !fromFinder, let item = find(url) {
                                _ = move(item)
                            } else {
                                do {
                                    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                                    let item = FileSystemItem(url: url, isDirectory: values.isDirectory == true)
                                    if !manager.copy(item, to: destination) { throw CocoaError(.fileWriteUnknown) }
                                    destination.isExpanded = true
                                } catch { showError(error) }
                            }
                        }
                    } else if let error { showError(error) }
                    load(index + 1)
                }
            }
        }
        load(0)
        return true
    }

    static func fileURL(_ value: NSSecureCoding?) -> URL? {
        let result: URL?
        if let url = value as? URL { result = url }
        else if let data = value as? Data { result = URL(dataRepresentation: data, relativeTo: nil) }
        else if let text = value as? String { result = URL(string: text) }
        else { result = nil }
        return result?.isFileURL == true ? result : nil
    }
    private static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.get("storage.operationFailed")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
