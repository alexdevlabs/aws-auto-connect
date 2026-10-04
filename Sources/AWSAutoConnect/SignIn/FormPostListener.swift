import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 that captures one form field a sign-in page posts back,
/// e.g. the SAMLResponse the AWS Client VPN SAML app posts to port 35001.
final class FormPostListener: @unchecked Sendable {
    let port: NWEndpoint.Port
    let field: String
    /// Added to the error when the port is taken.
    let busyHint: String
    /// Shown in the browser once the field arrived.
    let thanks: String

    private let queue = DispatchQueue(label: "aws-autoconnect.form-post")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    init(port: NWEndpoint.Port, field: String, busyHint: String = "", thanks: String = "Sign-in received. You can close this.") {
        self.port = port
        self.field = field
        self.busyHint = busyHint
        self.thanks = thanks
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state, let self {
                self.finish(.failure(AppError("Port \(self.port) is busy\(self.busyHint): \(error)")))
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    /// Fails a pending or future `response()` call.
    func fail(_ error: Error) {
        queue.async { self.finish(.failure(error)) }
    }

    func response() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let result = self.result {
                    cont.resume(with: result)
                } else {
                    self.continuation = cont
                }
            }
        }
    }

    // Must run on `queue`.
    private func finish(_ r: Result<String, Error>) {
        guard result == nil else { return }
        result = r
        continuation?.resume(with: r)
        continuation = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let body = Self.completeBody(buffer) {
                    self.respond(conn, body: body)
                } else if done || error != nil || buffer.count > 4 << 20 {
                    conn.cancel()
                } else {
                    receive()
                }
            }
        }
        receive()
    }

    private func respond(_ conn: NWConnection, body: Data) {
        let value = Self.formValue(field, in: String(decoding: body, as: UTF8.self))
        let page = value == nil
            ? "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            : "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n"
                + "<html><body style='font:15px -apple-system;padding:2em'>\(thanks)</body></html>"
        conn.send(content: Data(page.utf8), completion: .contentProcessed { _ in conn.cancel() })
        if let value { finish(.success(value)) }
    }

    /// Returns the request body once the headers and Content-Length bytes have arrived.
    static func completeBody(_ data: Data) -> Data? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var length = 0
        for line in head.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = data[end.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }

    static func formValue(_ key: String, in form: String) -> String? {
        for pair in form.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == key else { continue }
            return parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        return nil
    }
}
