import Foundation
import Darwin

/// Bounded JSONL RPC transport. Each owner uses a private connection; payloads are never logged.
@MainActor
final class CodexRPCConnection {
    enum Failure: Error { case unavailable, protocolError, stopped, timeout }
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 0
    private var buffer = Data()
    var onNotification: ((String, [String: Any]) -> Void)?
    var onClose: (() -> Void)?
    var running: Bool { process?.isRunning == true }

    func start(path: String, root: URL = LoreCodexEnvironment.directory) throws {
        try LoreCodexEnvironment.prepare(root: root)
        let task = Process()
        let stdin = Pipe(), stdout = Pipe()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = LoreCodexEnvironment.arguments + ["app-server", "--listen", "stdio://"]
        task.environment = LoreCodexEnvironment.environment(root: root)
        task.currentDirectoryURL = root
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor [weak self] in
                guard let self else { return }
                if bytes.isEmpty { close() } else { receive(bytes) }
            }
        }
        task.terminationHandler = { [weak self] _ in Task { @MainActor [weak self] in self?.close() } }
        process = task; input = stdin; output = stdout
        do { try task.run() } catch { close(); throw error }
    }

    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard running else { throw Failure.stopped }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try write(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.pending.removeValue(forKey: id)?.resume(throwing: Failure.timeout)
            }
        }
    }

    func notify(_ method: String) throws { try write(["method": method, "params": [:]]) }
    private func write(_ message: [String: Any]) throws {
        guard running, let input else { throw Failure.stopped }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    private func receive(_ bytes: Data) {
        buffer.append(bytes)
        guard buffer.count <= 2_000_000 else { close(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { close(); return }
            if let id = json["id"] as? Int, let reply = pending.removeValue(forKey: id) {
                if let result = json["result"] as? [String: Any] { reply.resume(returning: result) }
                else { reply.resume(throwing: Failure.protocolError) }
            } else if let id = json["id"], json["method"] != nil {
                // No interactive tool or permission approval UI is owned by this transport.
                // Reject explicitly rather than leaving the server waiting indefinitely.
                try? write(["id": id, "error": ["code": -32601, "message": "Client request unsupported"]])
            } else if let method = json["method"] as? String {
                onNotification?(method, json["params"] as? [String: Any] ?? [:])
            }
        }
    }
    func close() {
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; output = nil; buffer.removeAll()
        let waiting = pending; pending.removeAll()
        onClose?()
        for reply in waiting.values { reply.resume(throwing: Failure.stopped) }
    }
}
