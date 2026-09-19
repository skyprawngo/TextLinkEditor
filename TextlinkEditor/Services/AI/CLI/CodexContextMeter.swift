import Foundation

/// App-owned runtime metadata only. Never interprets cumulative billing as context occupancy.
enum CodexContextMeter {
    static func threshold(model: String?, root: URL) -> Int? {
        guard let model,
              let data = try? Data(contentsOf: root.appendingPathComponent("models_cache.json")),
              let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = catalog["models"] as? [[String: Any]],
              let entry = models.first(where: { $0["slug"] as? String == model }),
              let window = entry["context_window"] as? Int, window > 0, window < 100_000_000,
              let percent = entry["effective_context_window_percent"] as? Int, (1...100).contains(percent)
        else { return nil }
        // This explicit app policy is passed to exec, not guessed from provider defaults.
        return window * percent / 100 * 90 / 100
    }

    static func read(sessionID: String?, root: URL, limit: Int?, usage: AIContextUsage?) -> AIContextUsage? {
        guard let sessionID, UUID(uuidString: sessionID) != nil, var usage else { return usage }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                        options: [.skipsHiddenFiles]) else { return usage }
        // Executed once after a response, off the UI thread; bounded traversal and tail read.
        var visited = 0
        for case let file as URL in files {
            visited += 1
            if visited > 20_000 { break }
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                files.skipDescendants(); continue
            }
            guard file.lastPathComponent.hasSuffix("-\(sessionID).jsonl"),
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { return usage }
            let offset = size > 2_097_152 ? size - 2_097_152 : 0
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: 2_097_152) else { return usage }
            let lines = data.split(separator: 10, omittingEmptySubsequences: true)
            let completeLines = offset > 0 ? Array(lines.dropFirst()) : Array(lines)
            if let observation = latestObservation(lines: completeLines.map(Data.init)) {
                usage = AIContextUsage(inputTokens: usage.inputTokens, cachedTokens: usage.cachedTokens,
                                       outputTokens: usage.outputTokens, contextWindow: observation.window,
                                       currentContextTokens: observation.tokens,
                                       autoCompactTokenLimit: limit.flatMap { $0 <= observation.window ? $0 : nil })
            }
            return usage
        }
        return usage
    }

    static func latestObservation(lines: [Data]) -> (tokens: Int, window: Int)? {
        for line in lines.reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            // A post-compaction count is required; do not show the pre-compaction high-water mark.
            if event["type"] as? String == "compacted" { return nil }
            guard event["type"] as? String == "event_msg",
                  let payload = event["payload"] as? [String: Any] else { continue }
            if payload["type"] as? String == "context_compacted" { return nil }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let tokens = last["total_tokens"] as? Int, tokens >= 0,
                  let window = info["model_context_window"] as? Int, window > 0 else { continue }
            return (tokens, window)
        }
        return nil
    }
}
