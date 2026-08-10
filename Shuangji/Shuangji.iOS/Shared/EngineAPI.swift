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
    }

    public static func login(cfg: AppConfig, completion: @escaping (Result<Void, Error>) -> Void) {
        post(cfg, path: "/api/login", body: [
            "UserName": cfg.userName,
            "Password": cfg.password
        ], completion: { r in
            completion(r.map { _ in () })
        })
    }

    public static func setMode(cfg: AppConfig, mode: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        post(cfg, path: "/api/mode", body: [
            "UserName": cfg.userName,
            "Password": cfg.password,
            "Mode": mode
        ], completion: { r in
            completion(r.map { _ in () })
        })
    }

    public static func reset(cfg: AppConfig, completion: @escaping (Result<Void, Error>) -> Void) {
        post(cfg, path: "/api/reset", body: [
            "UserName": cfg.userName,
            "Password": cfg.password
        ], completion: { r in
            completion(r.map { _ in () })
        })
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
        URLSession.shared.dataTask(with: final) { data, _, err in
            if let err = err { completion(.failure(err)); return }
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

    private static func post(_ cfg: AppConfig, path: String, body: [String: Any],
                             completion: @escaping (Result<Data, Error>) -> Void) {
        guard let base = cfg.engineBaseURL else {
            completion(.failure(APIError.badURL)); return
        }
        var req = URLRequest(url: base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        // appendingPathComponent 会丢前导逻辑，直接拼
        req = URLRequest(url: URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            completion(.success(data ?? Data()))
        }.resume()
    }

    public enum APIError: Error {
        case badURL, empty
    }
}
