import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 and a random free port that receives the OAuth redirect.
/// Only loopback clients can connect. Each connection gets one response and is closed.
final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// First value per name.
        var query: [String: String]
    }

    /// A request waiting for its answer.
    struct Incoming: Sendable {
        var request: Request
        fileprivate let connection: NWConnection
        fileprivate let server: LoopbackServer

        func respond(status: Int, html: String) {
            server.send(status: status, html: html, on: connection)
        }
    }

    let requests: AsyncStream<Incoming>
    private let continuation: AsyncStream<Incoming>.Continuation
    private let queue = DispatchQueue(label: "dev.tern.mail.oauth-loopback")
    // Guarded by `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private static let maxHeaderBytes = 32 * 1024

    init() {
        (requests, continuation) = AsyncStream.makeStream(of: Incoming.self, bufferingPolicy: .unbounded)
    }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw GoogleAuthError.listenerFailed(String(describing: error))
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { (resume: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    if let port = listener.port?.rawValue {
                        resume.resume(returning: port)
                    } else {
                        resume.resume(throwing: GoogleAuthError.listenerFailed("no port"))
                    }
                case .failed(let error):
                    resumed = true
                    resume.resume(throwing: GoogleAuthError.listenerFailed(String(describing: error)))
                case .cancelled:
                    resumed = true
                    resume.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            queue.async {
                self.listener = listener
                listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        continuation.finish()
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }

    // MARK: - Connections (on `queue`)

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(buffer[..<headerEnd.lowerBound], on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else if buffer.count > Self.maxHeaderBytes {
                self.send(status: 431, html: "", on: connection)
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ head: Data, on connection: NWConnection) {
        let requestLine = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let words = requestLine.split(separator: " ")
        guard words.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + words[1]) else {
            send(status: 400, html: "", on: connection)
            return
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        let request = Request(method: String(words[0]), path: components.path.isEmpty ? "/" : components.path, query: query)
        continuation.yield(Incoming(request: request, connection: connection, server: self))
    }

    fileprivate func send(status: Int, html: String, on connection: NWConnection) {
        let body = Data(html.utf8)
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        let head = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
