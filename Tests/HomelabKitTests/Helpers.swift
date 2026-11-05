import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HomelabKit

/// Records requests and answers from a script.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = Data()
        var headers = ["Content-Type": "application/json"]
        var error: (any Error)?
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var handler: @Sendable (URLRequest) -> Reply

    init(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        self.handler = handler
    }

    convenience init(status: Int = 200, json: String) {
        self.init { _ in Reply(status: status, body: Data(json.utf8)) }
    }

    convenience init(status: Int = 200, fixture: String) {
        let data = Fixtures.data(fixture) ?? Data()
        self.init { _ in Reply(status: status, body: data) }
    }

    convenience init(error: any Error) {
        self.init { _ in Reply(error: error) }
    }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var last: URLRequest? { requests.last }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let r = handler(request)
        if let error = r.error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1",
                                       headerFields: r.headers)!
        return (r.body, response)
    }
}

func fixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    guard let data = Fixtures.data(name) else { throw TestFailure("fixture \(name) missing") }
    return try JSONDecoder().decode(T.self, from: data)
}

func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

func bodyJSON(_ request: URLRequest?) -> [String: String] {
    guard let data = request?.httpBody,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
    return obj
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

let base = URL(string: "https://homelab.example.ts.net")!

func temporaryDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("homelab-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
