import Foundation
import Network

/// 一次性本地 HTTP，用于把内置 Dopamine.tipa 交给 TrollStore `apple-magnifier://install?url=`
final class TinyHTTPServer {
    private var listener: NWListener?
    private let fileURL: URL
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.shuiyong.tipa.http")

    private(set) var baseURL: URL?

    init(fileURL: URL, port: UInt16 = 18473) {
        self.fileURL = fileURL
        self.port = port
    }

    func start() throws {
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        let sem = DispatchSemaphore(value: 0)
        var startErr: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sem.signal()
            case .failed(let e):
                startErr = e
                sem.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        _ = sem.wait(timeout: .now() + 5)
        if let startErr { throw startErr }
        baseURL = URL(string: "http://127.0.0.1:\(port)/Dopamine.tipa")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        baseURL = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let name = self.fileURL.lastPathComponent
            guard let body = try? Data(contentsOf: self.fileURL) else {
                conn.cancel()
                return
            }
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: application/octet-stream\r\n"
            header += "Content-Length: \(body.count)\r\n"
            header += "Content-Disposition: attachment; filename=\"\(name)\"\r\n"
            header += "Connection: close\r\n\r\n"
            var resp = Data(header.utf8)
            resp.append(body)
            conn.send(content: resp, completion: .contentProcessed { _ in
                conn.cancel()
            })
            _ = data
        }
    }
}
