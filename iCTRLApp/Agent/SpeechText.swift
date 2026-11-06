import Foundation

/// 読み上げの下ごしらえ。Foundation だけで書き、Mac の swiftc で試験できるようにしてある
/// （Scripts/test-voice-agent.sh）。
enum SpeechText {
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

    /// 英単語をカナに置き換える（端末内の声は Safari などを読み違えるため）。
    /// 長い語から順に、英字に挟まれていない所だけを、大小を区別せずに置き換える。
    /// GPU 機の検証（irodori-eval の gen.py）も同じ規則で同じ辞書を使う。
    static func applyReadings(_ text: String, _ readings: [String: String]) -> String {
        var result = text
        for word in readings.keys.sorted(by: { $0.count > $1.count }) {
            let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: readings[word]!)
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
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

/// 16bit リトルエンディアンの PCM を、-1...1 の Float に直す。
/// 断片の区切りが奇数バイトでも、余りを次の断片に持ち越して、サンプルがずれないようにする。
struct PCMDecoder {
    private var carry: UInt8?

    mutating func samples(_ data: Data) -> [Float] {
        var bytes = [UInt8](data)
        if let carry { bytes.insert(carry, at: 0) }
        carry = bytes.count % 2 == 1 ? bytes.removeLast() : nil
        var out = [Float](repeating: 0, count: bytes.count / 2)
        for i in 0..<out.count {
            let value = Int16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8)
            out[i] = Float(value) / 32768
        }
        return out
    }
}

/// 24kHz の音を 48kHz に直す（Gemini の声を、端末内の声と同じ再生ノードで鳴らすため）。
/// 隣り合うサンプルの中点を挟む。断片の境目でも、前の断片の最後のサンプルから続ける。
struct Upsampler2x {
    private var last: Float?

    mutating func process(_ samples: [Float]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(samples.count * 2)
        for sample in samples {
            out.append(((last ?? sample) + sample) / 2)
            out.append(sample)
            last = sample
        }
        return out
    }
}

/// Gemini の Interactions API が返す Server-Sent Events から、音声の断片を取り出す。
/// 1つのイベントの JSON が複数の data 行に分かれても読めるように、行をためてから解釈する。
struct SSEAudioParser {
    enum Failure: LocalizedError, Equatable {
        case stream(String)
        var errorDescription: String? {
            if case .stream(let message) = self { return "Gemini TTS stream error: \(message)" }
            return nil
        }
    }

    private var pending = ""
    private(set) var receivedAudio = false

    /// 1行を受け取り、そこまでで読めた音声の断片を返す。エラーのイベントなら投げる。
    mutating func feed(_ line: String) throws -> [Data] {
        if line.hasPrefix("event:") {
            // 次のイベントが始まった。読み切れずに残っていた行は捨てる。
            pending = ""
            return []
        }
        guard line.hasPrefix("data:") else { return [] }
        var payload = String(line.dropFirst(5))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        pending += pending.isEmpty ? payload : "\n" + payload
        guard let json = (try? JSONSerialization.jsonObject(with: Data(pending.utf8))) as? [String: Any] else {
            return []
        }
        pending = ""
        return try handle(json)
    }

    private mutating func handle(_ json: [String: Any]) throws -> [Data] {
        if let error = json["error"] as? [String: Any] {
            throw Failure.stream(error["message"] as? String ?? "error")
        }
        let type = json["event_type"] as? String
        if type == "error" {
            throw Failure.stream(json["message"] as? String ?? "error")
        }
        if type == "interaction.status_update", let status = json["status"] as? String,
           ["failed", "cancelled", "incomplete"].contains(status) {
            throw Failure.stream("interaction \(status)")
        }
        guard type == "step.delta",
              let delta = json["delta"] as? [String: Any], delta["type"] as? String == "audio",
              let base64 = delta["data"] as? String, let pcm = Data(base64Encoded: base64), !pcm.isEmpty else { return [] }
        receivedAudio = true
        return [pcm]
    }
}

/// 確認の質問への答えを読む。否定を含めば必ず拒否、肯定は短い発話に限る。分からなければ nil。
enum ConfirmationAnswer {
    static func interpret(_ text: String) -> Bool? {
        let t = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let negations = ["ない", "ません", "いいえ", "いや", "だめ", "ダメ", "やめ", "止め", "とめ", "待って", "まって",
                         "ストップ", "キャンセル", "ノー", "no", "中止", "結構"]
        if negations.contains(where: { t.contains($0) }) { return false }
        guard t.count <= 12 else { return nil }
        let affirmations = ["はい", "いいよ", "お願い", "おねがい", "オッケー", "ok", "うん", "どうぞ", "yes", "実行して", "進めて", "やって"]
        return affirmations.contains(where: { t.contains($0) }) ? true : nil
    }
}
