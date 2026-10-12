import Foundation
@testable import AudienceKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A canned response, or a transport failure.
enum StubResponse: Sendable {
    case json(status: Int, body: String)
    case failure(URLError)
}

/// A request as the stub saw it, with the body read out of its stream.
struct RecordedRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?

    var path: String { url.path }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func jsonBody() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any] ?? [:]
    }
}

/// Serves stubbed responses to one client. Each `Stub` gets its own host, so tests can run in parallel.
/// (A host rather than a header: Linux's Foundation doesn't pass session headers to URLProtocols.)
final class Stub: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]

    let id = UUID().uuidString.lowercased()
    private let lock = NSLock()
    private let handler: @Sendable (RecordedRequest) -> StubResponse
    private var recorded: [RecordedRequest] = []

    init(_ handler: @escaping @Sendable (RecordedRequest) -> StubResponse) {
        self.handler = handler
        Self.lock.withLock { Self.stubs[id] = self }
    }

    deinit {
        let id = id
        Self.lock.withLock { _ = Self.stubs.removeValue(forKey: id) }
    }

    var requests: [RecordedRequest] { lock.withLock { recorded } }

    /// The base URL to configure the client with.
    var baseURL: URL { URL(string: "https://\(id).\(StubURLProtocol.domain)")! }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func find(_ id: String) -> Stub? {
        lock.withLock { stubs[id] }
    }

    func respond(to request: RecordedRequest) -> StubResponse {
        lock.withLock { recorded.append(request) }
        return handler(request)
    }
}

final class StubURLProtocol: URLProtocol {
    static let domain = "stub.test"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.url?.host?.replacingOccurrences(of: ".\(Self.domain)", with: "") ?? ""
        guard let stub = Stub.find(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.read)
        )

        switch stub.respond(to: recorded) {
        case let .json(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
