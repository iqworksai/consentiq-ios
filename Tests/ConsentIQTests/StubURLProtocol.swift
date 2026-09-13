import Foundation
import XCTest
@testable import ConsentIQ

struct RecordedRequest {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    var path: String { url.path }

    var json: [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

struct StubResponse {
    let status: Int
    let body: Data

    init(status: Int = 200, json: String) {
        self.status = status
        self.body = Data(json.utf8)
    }

    init(status: Int, data: Data) {
        self.status = status
        self.body = data
    }
}

final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var routes: [String: StubResponse] = [:]
    private static var fallback: StubResponse?
    private static var recorded: [RecordedRequest] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = [:]
        fallback = nil
        recorded = []
    }

    static func stub(_ method: String, _ path: String, _ response: StubResponse) {
        lock.lock(); defer { lock.unlock() }
        routes["\(method) \(path)"] = response
    }

    static func stubFallback(_ response: StubResponse) {
        lock.lock(); defer { lock.unlock() }
        fallback = response
    }

    static var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func requests(matching method: String, _ path: String) -> [RecordedRequest] {
        requests.filter { $0.method == method && $0.path == path }
    }

    static var sessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let recordedRequest = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        let response: StubResponse?
        Self.lock.lock()
        Self.recorded.append(recordedRequest)
        response = Self.routes["\(recordedRequest.method) \(recordedRequest.path)"] ?? Self.fallback
        Self.lock.unlock()

        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
