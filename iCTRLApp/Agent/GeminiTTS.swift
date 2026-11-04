import Foundation

/// Gemini の音声合成（Interactions API）。1文ずつ、ストリーミングで PCM を受け取る。
/// Flash 系のモデルだけを使う。
struct GeminiTTS {
    enum Model: String, CaseIterable, Identifiable {
        case flash = "gemini-3.8-flash-tts"
        case flashLite = "gemini-3.8-flash-lite-tts"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .flash: return "Flash（表現力が高い）"
            case .flashLite: return "Flash-Lite（速くて安い）"
            }
        }
    }

    struct Voice: Identifiable {
        let name: String
        let character: String
        var id: String { name }
    }

    enum Failure: LocalizedError {
        case http(Int, String)
        case noAudio

        var errorDescription: String? {
            switch self {
            case .http(let status, let message): return "Gemini TTS error (HTTP \(status)): \(message)"
            case .noAudio: return "Gemini TTS returned no audio."
            }
        }
    }

    /// 公式ドキュメントの既定の声と、その性格。
    static let voices: [Voice] = [
        ("Zephyr", "明るい"), ("Puck", "弾む"), ("Charon", "知的"), ("Kore", "しっかり"), ("Fenrir", "興奮気味"),
        ("Leda", "若々しい"), ("Orus", "しっかり"), ("Aoede", "軽やか"), ("Callirrhoe", "おおらか"), ("Autonoe", "明るい"),
        ("Enceladus", "息まじり"), ("Iapetus", "澄んだ"), ("Umbriel", "おおらか"), ("Algieba", "なめらか"), ("Despina", "なめらか"),
        ("Erinome", "澄んだ"), ("Algenib", "しゃがれた"), ("Rasalgethi", "知的"), ("Laomedeia", "弾む"), ("Achernar", "柔らかい"),
        ("Alnilam", "しっかり"), ("Schedar", "落ち着いた"), ("Gacrux", "大人びた"), ("Pulcherrima", "はきはき"), ("Achird", "親しみやすい"),
        ("Zubenelgenubi", "くだけた"), ("Vindemiatrix", "穏やか"), ("Sadachbia", "生き生き"), ("Sadaltager", "物知り"), ("Sulafat", "温かい"),
    ].map { Voice(name: $0.0, character: $0.1) }

    static let keychainAccount = "gemini-api-key"
    private static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    private static let voiceKey = "agent.tts.voice"
    private static let modelKey = "agent.tts.model"

    static var selectedVoice: String {
        get { UserDefaults.standard.string(forKey: voiceKey) ?? "Achird" }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }

    static var selectedModel: Model {
        get { UserDefaults.standard.string(forKey: modelKey).flatMap(Model.init(rawValue:)) ?? .flash }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modelKey) }
    }

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

    /// 保存された設定で作る。キーが無ければ nil（iOS の声で読み上げる）。
    static func configured() -> GeminiTTS? {
        guard let key = storedKey() else { return nil }
        return GeminiTTS(apiKey: key, model: selectedModel, voice: selectedVoice)
    }

    let apiKey: String
    let model: Model
    let voice: String
    var style = "calm, warm and friendly, like a helpful assistant"

    /// 音声の形。ストリーミングは、ヘッダの無い 24kHz、モノラル、16bit の PCM で届く。
    static let sampleRate: Double = 24_000

    /// 1文をストリーミングで合成し、届いた PCM の断片を順に流す。
    /// 呼んだ時点で通信を始めるので、前の文を再生している間に次の文を作っておける。
    func stream(_ text: String) -> AsyncThrowingStream<Data, Error> {
        let request: URLRequest
        do {
            request = try makeRequest(text)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 300 { break } }
                        throw Failure.http(status, body)
                    }
                    var received = false
                    // Server-Sent Events。音声は step.delta の delta.data に base64 で入っている。
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:"),
                              let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { continue }
                        if let error = json["error"] as? [String: Any] {
                            throw Failure.http(status, error["message"] as? String ?? "stream error")
                        }
                        guard json["event_type"] as? String == "step.delta",
                              let delta = json["delta"] as? [String: Any], delta["type"] as? String == "audio",
                              let base64 = delta["data"] as? String, let pcm = Data(base64Encoded: base64) else { continue }
                        received = true
                        continuation.yield(pcm)
                    }
                    if !received { throw Failure.noAudio }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(_ text: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "model": model.rawValue,
            "input": [[
                "type": "user_input",
                "content": [[
                    "type": "text",
                    "text": text,
                    "annotations": [["type": "speech_metadata", "style": style]],
                ]],
            ]],
            "response_format": ["type": "audio", "mime_type": "audio/l16", "sample_rate": Int(Self.sampleRate)],
            "generation_config": ["speech_config": [["voice": voice]]],
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// 読み上げる文を、1文ずつに分ける。短すぎる断片は前の文につなげる。
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "。！？!?\n".contains(character) {
                append(&result, current)
                current = ""
            }
        }
        append(&result, current)
        return result
    }

    private static func append(_ result: inout [String], _ piece: String) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.count < 6, let last = result.popLast() {
            result.append(last + trimmed)
        } else {
            result.append(trimmed)
        }
    }
}
