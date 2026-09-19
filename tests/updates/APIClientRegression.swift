import Foundation

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var response = Data(#"{"license_status":"valid","update_available":false}"#.utf8)
    static var requestBody: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/v1/releases/latest" {
            precondition(request.httpMethod == "GET")
            precondition(request.httpBody == nil && request.httpBodyStream == nil)
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(Set(query.map(\.name)) == Set(["version", "build"]))
        } else {
            precondition(request.url?.absoluteString == "https://textlinkeditor.skyprawngo.com/v1/check")
            precondition(request.httpMethod == "POST")
            precondition(request.url?.query == nil)
        }
        precondition(request.value(forHTTPHeaderField: "User-Agent") == "TextlinkEditor/1.0.0")
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            Self.requestBody = try! JSONDecoder().decode([String: String].self, from: data)
        } else if let data = request.httpBody {
            Self.requestBody = try! JSONDecoder().decode([String: String].self, from: data)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct Regression {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = UpdateAPIClient(configuration: config)
        StubProtocol.response = Data(#"{"update_available":true,"release":{"build":"3","version":"1.1.0","notes":"- Fix saving","minimum_os":"26.0"}}"#.utf8)
        let metadata = try await client.latest(version: "1.0.0", build: "2")
        precondition(metadata.release?.notes == "- Fix saving")
        precondition(StubProtocol.requestBody.isEmpty)
        StubProtocol.response = Data(#"{"license_status":"valid","update_available":false}"#.utf8)
        let response = try await client.check(deviceID: "fixture", appKey: "fixture-key", version: "1.0.0", build: "2")
        precondition(response.license_status == "valid" && !response.update_available)
        precondition(StubProtocol.requestBody == ["device_id": "fixture", "app_key": "fixture-key", "version": "1.0.0", "build": "2"])
        StubProtocol.status = 401
        do {
            _ = try await client.check(deviceID: "fixture", appKey: "fixture-key", version: "1.0.0", build: "2")
            fatalError("accepted HTTP failure")
        } catch is URLError {}
        StubProtocol.status = 200
        StubProtocol.response = Data("not json".utf8)
        do {
            _ = try await client.check(deviceID: "fixture", appKey: "fixture-key", version: "1.0.0", build: "2")
            fatalError("accepted malformed response")
        } catch is DecodingError {}
        print("PASS: request identity/version/body, HTTP failure, malformed response")
    }
}
