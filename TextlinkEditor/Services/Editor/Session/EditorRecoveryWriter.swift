import Foundation

/// Serializes immutable recovery snapshots and rejects obsolete completion callbacks.
/// Entry points and completion delivery belong to the main thread; only I/O crosses the queue.
final class EditorRecoveryWriter {
    private let queue = DispatchQueue(label: "TextlinkEditor.recovery", qos: .utility)
    private var generation = 0

    func write(asynchronously: Bool, operation: @escaping () -> String?, completion: @escaping (String?) -> Void) {
        generation &+= 1
        let requestedGeneration = generation
        if asynchronously {
            queue.async { [weak self] in
                let error = operation()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == requestedGeneration else { return }
                    completion(error)
                }
            }
        } else {
            // Explicit save/close waits for older autosaves before writing the final snapshot.
            completion(queue.sync(execute: operation))
        }
    }

    func invalidateAndWait() {
        queue.sync {}
        generation &+= 1
    }
}
