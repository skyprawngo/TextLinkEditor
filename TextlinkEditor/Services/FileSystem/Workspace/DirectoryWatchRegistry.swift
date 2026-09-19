import Foundation

/// Owns directory descriptors and cancellation. Consumers decide how to refresh their models.
final class DirectoryWatchRegistry {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]

    func watch(_ url: URL, onChange: @escaping () -> Void) {
        let path = url.path
        guard sources[path] == nil else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        sources[path] = source
        source.resume()
    }

    func contains(_ url: URL) -> Bool { sources[url.path] != nil }

    func stop(under url: URL) {
        for path in Array(sources.keys) where DocumentFileStore.contains(URL(fileURLWithPath: path), in: url) {
            sources.removeValue(forKey: path)?.cancel()
        }
    }

    func stopAll() {
        for source in sources.values { source.cancel() }
        sources.removeAll()
    }

    deinit { stopAll() }
}
