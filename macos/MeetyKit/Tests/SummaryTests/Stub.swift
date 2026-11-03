import Foundation
import Synchronization

/// A request as the stub saw it, with the body read back from its stream.
struct Seen: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
}

/// What the stub answers: status, body, and an optional delay before the reply.
struct Reply: Sendable {
    var status = 200
    var body = Data()
    var delay: Duration = .zero
    init(_ status: Int = 200, _ body: String = "", delay: Duration = .zero) {
        self.status = status
        self.body = Data(body.utf8)
        self.delay = delay
    }
}

/// A fake HTTP server behind `URLProtocol`. Each `Stub` has its own session and handler, so tests run in parallel.
final class Stub: Sendable {
    let session: URLSession
    let seen = Mutex<[Seen]>([])
    private let id = UUID().uuidString
    private let handler: @Sendable (Seen) -> Reply

    init(_ handler: @escaping @Sendable (Seen) -> Reply) {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub": id]
        session = URLSession(configuration: configuration)
        Self.registry.withLock { $0[id] = self }
    }

    var requests: [Seen] { seen.withLock { $0 } }

    static let registry = Mutex<[String: Stub]>([:])

    func reply(to request: Seen) -> Reply {
        seen.withLock { $0.append(request) }
        return handler(request)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private var reply: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Stub"), let stub = Stub.registry.withLock({ $0[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let seen = Seen(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        let answer = stub.reply(to: seen)
        let url = request.url!
        let box = Unchecked(value: self)
        reply = Task {
            let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            if answer.delay > .zero { try? await Task.sleep(for: answer.delay) }
            guard !Task.isCancelled else { return }
            let this = box.value
            this.client?.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
            this.client?.urlProtocol(this, didLoad: answer.body)
            this.client?.urlProtocolDidFinishLoading(this)
        }
    }

    override func stopLoading() { reply?.cancel() }
}

struct Unchecked<T>: @unchecked Sendable { let value: T }
