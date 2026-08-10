import Foundation

/// 对接 Shuangji Engine 网页同款 API（默认 :8088）。
public enum EngineAPI {

    public struct Status: Decodable {
        public let Mode: Int?
        public let PoolCount: Int?
        public let ReadyText: String?
        public let ModifyCount: Int?
        public let BoostInterceptCount: Int?
        public let GreenFrozen: Bool?
        public let ReadyModify: Bool?
        public let ReadyLobby: Bool?
    }

    public struct APIResult: Decodable {
        public let ok: Bool?
        public let Ok: Bool?
        public let message: String?
        public let Message: String?

        public var succeeded: Bool { (ok ?? Ok) == true }
        public var text: String { message ?? Message ?? "" }
    }

    public static func modeName(_ m: Int) -> String {
        switch m {
        case 0: return "待机"
        case 1: return "读取"
        case 2: return "修改"
        case 3: return "大厅"
        default: return "未知(\(m))"
        }
    }

    public static func login(cfg: AppConfig, completion: @escaping (Result<String, Error>) -> Void) {
        postJSON(cfg, path: "/api/login", body: [
            "UserName": cfg.userName,
            "Password": cfg.password
        ], completion: completion)
    }

    public static func setMode(cfg: AppConfig, mode: Int, completion: @escaping (Result<String, Error>) -> Void) {
        // 先登录再切模式，避免未鉴权/缓存导致假成功
        login(cfg: cfg) { loginResult in
            if case .failure(let e) = loginResult {
                completion(.failure(e))
                return
            }
            postJSON(cfg, path: "/api/mode", body: [
                "UserName": cfg.userName,
                "Password": cfg.password,
                "Mode": mode
            ], completion: completion)
        }
    }

    public static func reset(cfg: AppConfig, completion: @escaping (Result<String, Error>) -> Void) {
        postJSON(cfg, path: "/api/reset", body: [
            "UserName": cfg.userName,
            "Password": cfg.password
        ], completion: completion)
    }

    public static func status(cfg: AppConfig, completion: @escaping (Result<Status, Error>) -> Void) {
        guard var url = cfg.engineBaseURL else {
            completion(.failure(APIError.badURL)); return
        }
        url.appendPathComponent("api/status")
        var comp = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comp.queryItems = [
            URLQueryItem(name: "user", value: cfg.userName),
            URLQueryItem(name: "pass", value: cfg.password)
        ]
        guard let final = comp.url else {
            completion(.failure(APIError.badURL)); return
        }
        URLSession.shared.dataTask(with: final) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(APIError.http(http.statusCode))); return
            }
            guard let data = data else {
                completion(.failure(APIError.empty)); return
            }
            do {
                let s = try JSONDecoder().decode(Status.self, from: data)
                completion(.success(s))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func postJSON(_ cfg: AppConfig, path: String, body: [String: Any],
                                 completion: @escaping (Result<String, Error>) -> Void) {
        guard let base = cfg.engineBaseURL else {
            completion(.failure(APIError.badURL)); return
        }
        let urlStr = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
        guard let url = URL(string: urlStr) else {
            completion(.failure(APIError.badURL)); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(APIError.http(http.statusCode))); return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(APIError.empty)); return
            }
            if let parsed = try? JSONDecoder().decode(APIResult.self, from: data) {
                if parsed.succeeded {
                    completion(.success(parsed.text.isEmpty ? "OK" : parsed.text))
                } else {
                    completion(.failure(APIError.server(parsed.text.isEmpty ? "引擎拒绝" : parsed.text)))
                }
                return
            }
            // 非 JSON 也当成功文本
            completion(.success(String(data: data, encoding: .utf8) ?? "OK"))
        }.resume()
    }

    public enum APIError: LocalizedError {
        case badURL, empty, http(Int), server(String)
        public var errorDescription: String? {
            switch self {
            case .badURL: return "引擎地址无效"
            case .empty: return "引擎无响应"
            case .http(let c): return "HTTP \(c)"
            case .server(let s): return s
            }
        }
    }
}
