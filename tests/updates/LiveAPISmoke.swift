import Foundation

/// Explicit deployment smoke test: contacts the production API without identity or credentials.
@main struct LiveAPISmoke {
    static func main() async {
        do {
            let result = try await UpdateAPIClient().latest(version: "0.1.0", build: "1")
            precondition(!result.update_available || result.release != nil)
            print("PASS: native URLSession public metadata request")
        } catch {
            print("FAIL: native HTTPS request: \(error.localizedDescription)")
            exit(1)
        }
    }
}
