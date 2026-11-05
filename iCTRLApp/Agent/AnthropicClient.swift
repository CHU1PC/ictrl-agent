import Foundation

/// Claude Messages API の最小クライアント。
/// Swift には公式 SDK が無いので、/v1/messages を HTTP で直接呼ぶ。
struct AnthropicClient {
    enum Failure: LocalizedError {
        case missingKey
        case http(Int, String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Claude API key is not set."
            case .http(let status, let message): return "Claude API error (HTTP \(status)): \(message)"
            case .malformed: return "Claude API returned an unreadable response."
            }
        }

        /// 読み上げ用の短い日本語。詳細は画面に出す。
        var spokenText: String {
            switch self {
            case .missingKey: return "API キーが設定されていません。"
            case .http(let status, _) where status == 401 || status == 403: return "API キーが受け付けられませんでした。"
            case .http(let status, _) where status == 429: return "API の利用上限に達しました。少し待ってください。"
            case .http(let status, _) where status >= 500: return "Claude のサーバーが混み合っています。"
            case .http: return "Claude へのリクエストが失敗しました。"
            case .malformed: return "Claude の応答を読めませんでした。"
            }
        }
    }

    enum Model: String, CaseIterable, Identifiable {
        case sonnet = "claude-sonnet-5-5"
        case haiku = "claude-haiku-5-5"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .sonnet: return "Sonnet 5.5（標準）"
            case .haiku: return "Haiku 5.5（速くて安いが、迷いやすい）"
            }
        }
    }

    /// 1つの会話のあいだは変えない設定。途中で考え方を変えると API に拒否されることがある。
    struct Config: Equatable {
        var model: Model
        /// true なら effort を low にして、考える過程（thinking）を切る。
        var fast: Bool

        private static let modelKey = "agent.claude.model"
        private static let fastKey = "agent.claude.fast"

        static var stored: Config {
            get {
                let defaults = UserDefaults.standard
                let model = defaults.string(forKey: modelKey).flatMap(Model.init(rawValue:)) ?? .sonnet
                let fast = defaults.object(forKey: fastKey) as? Bool ?? true
                return Config(model: model, fast: fast)
            }
            set {
                UserDefaults.standard.set(newValue.model.rawValue, forKey: modelKey)
                UserDefaults.standard.set(newValue.fast, forKey: fastKey)
            }
        }
    }

    static let keychainAccount = "anthropic-api-key"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxAttempts = 4

    let apiKey: String
    let config: Config

    static func storedKey() -> String? {
        guard let data = KeychainStore.load(account: keychainAccount),
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func storeKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.clear(account: keychainAccount)
        } else {
            KeychainStore.save(Data(trimmed.utf8), account: keychainAccount)
        }
    }

    /// 1往復分のリクエストを送り、レスポンスの JSON をそのまま返す。
    /// 429、529、5xx、通信断は、retry-after か指数バックオフで再試行する。
    func send(system: [[String: Any]], tools: [[String: Any]], messages: [[String: Any]]) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": config.model.rawValue,
            "max_tokens": 16000,
            "system": system,
            "tools": tools,
            "messages": messages,
            "cache_control": ["type": "ephemeral"],
            "output_config": ["effort": config.fast ? "low" : "medium"],
            "context_management": ["edits": [["type": "clear_tool_uses_20250919"]]],
        ]
        // 古いツール結果を消す context editing は、どちらのモデルでも使う。
        var betas = ["context-management-2025-06-27"]
        switch config.model {
        case .sonnet:
            // 断られたときに別のモデルで続ける。Sonnet 5.5 は "default" の形だけを受け付ける。
            body["fallbacks"] = "default"
            betas.append("server-side-fallback-2026-07-01")
            // Sonnet 5.5 で考える過程を切るのは disabled ではなく between_tools（effort high 以下）。
            if config.fast { body["thinking"] = ["type": "between_tools"] }
        case .haiku:
            // Haiku 5.5 にはサーバー側の切り替えが無い。disabled は effort high 以下で使える。
            if config.fast { body["thinking"] = ["type": "disabled"] }
        }
        // キーの順を固定して、プロンプトキャッシュの前方一致を崩さない。
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await post(payload, betas: betas.joined(separator: ","))
            } catch let failure as RetryableFailure {
                guard attempt < Self.maxAttempts else { throw failure.underlying }
                let delay = failure.retryAfter ?? min(pow(2, Double(attempt)), 20)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private struct RetryableFailure: Error {
        let underlying: Error
        let retryAfter: TimeInterval?
    }

    private func post(_ payload: Data, betas: String) async throws -> [String: Any] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue(betas, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = payload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw RetryableFailure(underlying: error, retryAfter: nil)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if status == 429 || status >= 500 {
                throw RetryableFailure(underlying: Failure.http(status, "unreadable body"), retryAfter: nil)
            }
            throw Failure.malformed
        }
        guard status == 200 else {
            let error = json["error"] as? [String: Any]
            let failure = Failure.http(status, error?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self))
            if status == 429 || status >= 500 {
                let retryAfter = (http?.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init)
                throw RetryableFailure(underlying: failure, retryAfter: retryAfter)
            }
            throw failure
        }
        return json
    }
}
