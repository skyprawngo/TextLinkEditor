import Foundation

struct PublishedUpdate: Decodable {
    let build: String
    let version: String
    let notes: String
    let minimum_os: String
}

struct ReleaseCheckResponse: Decodable {
    let update_available: Bool
    let release: PublishedUpdate?
}

struct UpdateCheckResponse: Decodable {
    let license_status: String
    let update_available: Bool
    let token: String?
    let latest_version: String?
}

/// Ephemeral session: no disk cache, cookies, credentials cache, or cross-origin redirects.
final class UpdateAPIClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let origin = URL(string: "https://textlinkeditor.skyprawngo.com")!

    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }

    func latest(version: String, build: String) async throws -> ReleaseCheckResponse {
        var components = URLComponents(url: Self.origin.appendingPathComponent("v1/releases/latest"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "build", value: build), URLQueryItem(name: "version", value: version)]
        var request = URLRequest(url: components.url!)
        request.setValue("TextlinkEditor/\(version)", forHTTPHeaderField: "User-Agent")
        return try await send(request)
    }

    func check(deviceID: String, appKey: String, version: String, build: String, targetBuild: String? = nil) async throws -> UpdateCheckResponse {
        var request = URLRequest(url: Self.origin.appendingPathComponent("v1/check"))
        request.httpMethod = "POST"
        request.setValue("TextlinkEditor/\(version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CheckRequest(device_id: deviceID,
            app_key: appKey, version: version, build: build, target_build: targetBuild))
        return try await send(request)
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let config = configuration
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private struct CheckRequest: Encodable {
        let device_id: String
        let app_key: String
        let version: String
        let build: String
        let target_build: String?
    }
}
