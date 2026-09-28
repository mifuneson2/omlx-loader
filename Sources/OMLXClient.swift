import Foundation

/// One model as reported by oMLX's `/v1/models/status`.
struct ModelInfo: Decodable, Equatable {
    let id: String
    let loaded: Bool
    let isLoading: Bool
    let estimatedSize: Int64?
}

/// Response of `/v1/models/status`.
struct ModelStatus: Decodable {
    let maxModelMemory: Int64?
    let currentModelMemory: Int64?
    let models: [ModelInfo]

    var loadedModels: [ModelInfo] { models.filter { $0.loaded } }
    var loadingModels: [ModelInfo] { models.filter { $0.isLoading } }
}

enum OMLXError: LocalizedError {
    case http(Int, String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "oMLX returned HTTP \(code): \(body.prefix(200))"
        case .notRunning: return "oMLX is not running"
        }
    }
}

/// Settings read from `~/.omlx/settings.json` (port and model directory).
struct OMLXSettings {
    var port: Int = 8000
    var modelDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("models")
    var apiKey: String?

    static func load() -> OMLXSettings {
        var s = OMLXSettings()
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omlx/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return s }
        if let server = json["server"] as? [String: Any], let port = server["port"] as? Int {
            s.port = port
        }
        if let model = json["model"] as? [String: Any], let dir = model["model_dir"] as? String {
            s.modelDir = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        if let auth = json["auth"] as? [String: Any], let key = auth["api_key"] as? String, !key.isEmpty {
            s.apiKey = key
        }
        return s
    }

    /// Model names from the model directory — used to offer models while oMLX is stopped.
    func modelsOnDisk() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }
}

/// Thin HTTP client for the local oMLX server.
final class OMLXClient {
    let settings: OMLXSettings
    private let session: URLSession

    init(settings: OMLXSettings = .load()) {
        self.settings = settings
        let config = URLSessionConfiguration.ephemeral
        // Loading an 80 GB model can take minutes; the load call only returns when it's done.
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config)
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(settings.port)")! }
    var dashboardURL: URL { baseURL.appendingPathComponent("admin") }

    func isHealthy() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func status() async throws -> ModelStatus {
        let (data, _) = try await send("GET", "v1/models/status", timeout: 5)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ModelStatus.self, from: data)
    }

    /// Loads a model. Uses the admin endpoint; if that needs a login (an API key was
    /// set up), falls back to a 1-token completion, which makes oMLX load the model.
    func load(_ id: String) async throws {
        do {
            _ = try await send("POST", "admin/api/models/\(escape(id))/load")
        } catch OMLXError.http(409, _) {
            return // already loading
        } catch OMLXError.http(let code, _) where code == 401 || code == 403 {
            let body: [String: Any] = [
                "model": id,
                "messages": [["role": "user", "content": "hi"]],
                "max_tokens": 1,
            ]
            _ = try await send("POST", "v1/chat/completions", json: body)
        }
    }

    func unload(_ id: String) async throws {
        do {
            _ = try await send("POST", "v1/models/\(escape(id))/unload")
        } catch OMLXError.http(400, _) {
            return // not loaded
        }
    }

    // MARK: - Private

    private func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }

    @discardableResult
    private func send(_ method: String, _ path: String, json: [String: Any]? = nil,
                      timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        if let key = settings.apiKey { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw OMLXError.notRunning
        }
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw OMLXError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return (data, http)
    }
}
