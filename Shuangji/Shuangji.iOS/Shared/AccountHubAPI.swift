import Foundation

/// 直接对接账号中枢 AccountServer（默认 175.27.250.54:9100），不经 Engine。
public enum AccountHubAPI {

    public struct AuthResult {
        public let ok: Bool
        public let message: String
        public let token: String?
        public let maxConnections: Int
    }

    public static func auth(host: String, port: Int, user: String, password: String,
                            completion: @escaping (Result<AuthResult, Error>) -> Void) {
        let urlStr = "http://\(host):\(port)/api/auth"
        guard let url = URL(string: urlStr) else {
            completion(.failure(HubError.badURL)); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        let body: [String: Any] = ["UserName": user, "Password": password]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(HubError.http(http.statusCode))); return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(HubError.empty)); return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(HubError.badJSON)); return
            }
            let ok = (obj["Ok"] as? Bool) ?? (obj["ok"] as? Bool) ?? false
            let msg = (obj["Message"] as? String) ?? (obj["message"] as? String) ?? ""
            let token = (obj["Token"] as? String) ?? (obj["token"] as? String)
            let maxC = (obj["MaxConnections"] as? Int) ?? (obj["maxConnections"] as? Int) ?? 0
            if ok {
                completion(.success(AuthResult(ok: true, message: msg.isEmpty ? "OK" : msg,
                                               token: token, maxConnections: maxC)))
            } else {
                completion(.failure(HubError.denied(msg.isEmpty ? "账号或密码错误" : msg)))
            }
        }.resume()
    }

    public static func ping(host: String, port: Int, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://\(host):\(port)/api/ping") else {
            completion(false); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
            completion(ok)
        }.resume()
    }

    public enum HubError: LocalizedError {
        case badURL, empty, badJSON, http(Int), denied(String)
        public var errorDescription: String? {
            switch self {
            case .badURL: return "中枢地址无效"
            case .empty: return "中枢无响应"
            case .badJSON: return "中枢返回异常"
            case .http(let c): return "中枢 HTTP \(c)"
            case .denied(let s): return s
            }
        }
    }
}
