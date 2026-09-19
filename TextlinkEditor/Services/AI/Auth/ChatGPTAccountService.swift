import AppKit
import Observation

/// The official runtime owns OAuth PKCE, callback validation, refresh and macOS Keychain storage.
/// TextlinkEditor never reads or copies access/refresh tokens from another application's account.
enum LoreCodexEnvironment {
    // Legacy storage identity retained for existing user data after the product rename.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Loreweave/OpenAI", isDirectory: true)
    }
    static let arguments = ["-c", "cli_auth_credentials_store=\"keyring\"", "-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\""]
    static func environment(root: URL = directory) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys) where key.hasPrefix("OPENAI_") || key.hasPrefix("CODEX_") { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = root.path
        env["PATH"] = CLIDetector.searchPaths.joined(separator: ":")
        return env
    }
    static func prepare(root: URL = directory) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

struct ChatGPTAccount: Equatable {
    let email: String
    let plan: String
    static func parse(_ result: [String: Any]) -> ChatGPTAccount? {
        guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" else { return nil }
        return ChatGPTAccount(email: account["email"] as? String ?? "ChatGPT", plan: account["planType"] as? String ?? "")
    }
}

@MainActor @Observable
final class ChatGPTAccountService {
    private(set) var account: ChatGPTAccount?
    private(set) var isBusy = false
    private(set) var loginPending = false
    private(set) var errorMessage: String?
    private(set) var limits: String?
    private var rpc: CodexRPCConnection?
    private var loginID: String?
    private var generation = UUID()
    private var expiry: Task<Void, Never>?

    func refresh() async {
        guard !isBusy, !loginPending else { return }
        isBusy = true
        errorMessage = nil
        let owner = generation
        defer { if generation == owner { isBusy = false } }
        do {
            let rpc = try await server()
            let result = try await rpc.request("account/read", ["refreshToken": false])
            guard owner == generation else { return }
            account = ChatGPTAccount.parse(result)
        } catch { if owner == generation { errorMessage = L10n.get("ai.oauth.connectionFailed") } }
    }

    func login() async {
        guard !isBusy, !loginPending else { return }
        isBusy = true
        errorMessage = nil
        let owner = generation
        defer { if owner == generation { isBusy = false } }
        do {
            let rpc = try await server()
            let result = try await rpc.request("account/login/start", ["type": "chatgpt"])
            guard owner == generation else { return }
            guard let id = result["loginId"] as? String, let value = result["authUrl"] as? String,
                  let url = Self.validLoginURL(value) else { throw CodexRPCConnection.Failure.protocolError }
            loginID = id
            loginPending = true
            guard NSWorkspace.shared.open(url) else { cancelLogin(); errorMessage = L10n.get("ai.oauth.browserFailed"); return }
            expiry?.cancel()
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled, let self, generation == owner, loginID == id else { return }
                cancelLogin()
                errorMessage = L10n.get("ai.oauth.expired")
            }
        } catch { if owner == generation { errorMessage = L10n.get("ai.oauth.connectionFailed") } }
    }

    static func validLoginURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              ["auth.openai.com", "auth0.openai.com", "chatgpt.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        return url
    }

    func cancelLogin() {
        // Closing this private server drops its callback listener and invalidates pending RPCs.
        generation = UUID()
        expiry?.cancel()
        loginID = nil
        loginPending = false
        isBusy = false
        rpc?.close()
        rpc = nil
    }

    func logout() async {
        guard !isBusy else { return }
        cancelLogin()
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let rpc = try await server()
            _ = try await rpc.request("account/logout")
            account = nil
            limits = nil
        } catch { errorMessage = L10n.get("ai.oauth.logoutFailed") }
    }

    func refreshLimits() async {
        guard account != nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let rpc = try await server()
            let result = try await rpc.request("account/rateLimits/read")
            let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
            let values = buckets?.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
                ?? [("Codex", result["rateLimits"] as? [String: Any] ?? [:])]
            limits = values.flatMap { name, bucket in
                ["primary", "secondary"].compactMap { key -> String? in
                    guard let window = bucket[key] as? [String: Any], let used = window["usedPercent"] as? Double else { return nil }
                    let minutes = window["windowDurationMins"] as? Int ?? 0
                    return "\(name) · \(minutes) min · \(Int(max(0, min(100, 100-used))))% " + L10n.get("ai.oauth.remaining")
                }
            }.joined(separator: "\n")
            if limits?.isEmpty == true { limits = L10n.get("ai.oauth.limitsUnavailable") }
        } catch { limits = L10n.get("ai.oauth.limitsUnavailable") }
    }

    func availableModels() async throws -> [AIModelOption] {
        let owner = generation
        let client = try await server()
        var models: [AIModelOption] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let result = try await client.request("model/list", params)
            guard owner == generation, !Task.isCancelled else { throw CancellationError() }
            guard let data = result["data"] as? [[String: Any]] else { throw CodexRPCConnection.Failure.protocolError }
            models += data.compactMap(AIModelOption.parse).filter { option in !models.contains { $0.id == option.id } }
            cursor = result["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw CodexRPCConnection.Failure.protocolError }
        } while cursor != nil
        return models
    }

    private func server() async throws -> CodexRPCConnection {
        if let rpc, rpc.running { return rpc }
        let owner = generation
        guard let path = await CLIDetector.shared.resolvedPath(for: .chatgpt) else { throw CodexRPCConnection.Failure.unavailable }
        guard owner == generation, !Task.isCancelled else { throw CancellationError() }
        let client = CodexRPCConnection()
        client.onNotification = { [weak self] method, params in self?.notification(method, params) }
        try client.start(path: path)
        rpc = client
        do {
            _ = try await client.request("initialize", ["clientInfo": ["name": "textlinkeditor", "title": "TextlinkEditor", "version": "1.0"]])
            try client.notify("initialized")
            return client
        } catch { client.close(); if rpc === client { rpc = nil }; throw error }
    }

    private func notification(_ method: String, _ params: [String: Any]) {
        guard method == "account/login/completed", let id = params["loginId"] as? String, id == loginID else { return }
        expiry?.cancel()
        loginID = nil
        loginPending = false
        if params["success"] as? Bool == true {
            Task { await refresh() }
        } else { errorMessage = L10n.get("ai.oauth.loginFailed") }
    }
}
