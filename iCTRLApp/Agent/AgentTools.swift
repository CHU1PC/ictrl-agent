import CoreGraphics
import Foundation

/// ランナーの RPC を Claude のツール定義に変換し、ツール結果を API の形に整える。
enum AgentTools {
    static let confirmToolName = "confirm_with_user"

    /// サーバー管理用で、エージェントに触らせない RPC。
    private static let excluded: Set<String> = ["config", "stream_ticket", "logs", "reset", "lock", "list_apps"]

    /// ツール結果の文字列の上限。超えた分は切ったことをモデルに明示する。
    private static let maxResultChars = 30_000

    static var definitions: [[String: Any]] {
        var tools: [[String: Any]] = RPCMethodRegistry.methods
            .filter { !excluded.contains($0.name) }
            .map { method in
                var properties: [String: Any] = [:]
                for param in method.params {
                    var schema: [String: Any] = ["type": param.type, "description": param.description]
                    if param.type == "array" { schema["items"] = ["type": "object"] }
                    properties[param.name] = schema
                }
                return [
                    "name": method.name,
                    "description": "\(method.description)\n\nReturns: \(method.returns)",
                    "input_schema": [
                        "type": "object",
                        "properties": properties,
                        "required": method.params.filter(\.required).map(\.name),
                    ] as [String: Any],
                ]
            }
        tools.append([
            "name": confirmToolName,
            "description": "Ask the user out loud for permission and wait for a yes or no. Call this BEFORE any action that sends or posts a message, makes a purchase or payment, deletes data, or changes a setting or account. The summary must say exactly what will happen, in one short Japanese sentence. Returns {approved: true|false}. If not approved, do not perform the action. An approval covers only the next few actions of this one step.",
            "input_schema": [
                "type": "object",
                "properties": ["summary": ["type": "string", "description": "One Japanese sentence describing exactly what will happen"]],
                "required": ["summary"],
            ] as [String: Any],
        ])
        return tools
    }

    /// 実行前に入力を整える。スクリーンショットは既定で scale 1 にして、
    /// 画像を小さく保つ（履歴に溜まっても送信量が膨らまない。座標も point と一致する）。
    static func prepare(method: String, input: [String: Any]) -> [String: Any] {
        guard method == "screenshot" else { return input }
        var input = input
        if input["scale"] == nil { input["scale"] = 1 }
        if input["format"] == nil { input["format"] = "jpeg" }
        if input["quality"] == nil { input["quality"] = 0.5 }
        return input
    }

    /// RPC の結果を tool_result の content にする。スクリーンショットは画像ブロックにする。
    static func resultContent(for result: [String: Any]) -> [[String: Any]] {
        var content: [[String: Any]] = []
        var rest = result
        if let data = result["data"] as? String, let format = result["format"] as? String {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": format == "png" ? "image/png" : "image/jpeg", "data": data],
            ])
            rest["data"] = nil
        }
        content.append(["type": "text", "text": jsonText(rest)])
        return content
    }

    static func jsonText(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return String(describing: object)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text.count > maxResultChars else { return text }
        return String(text.prefix(maxResultChars)) + "\n[truncated: \(text.count - maxResultChars) more characters. Narrow the request with filter, visible_only or max_elements.]"
    }
}

/// 危険な操作の二重チェック。モデルの自己申告（confirm_with_user）に加えて、
/// 押そうとしている要素とアプリを見て、確認を経ていなければ止める。
struct RiskGuard {
    /// 日本語は部分一致で見る。
    private static let japaneseKeywords = [
        "送信", "投稿", "購入", "注文", "支払", "決済", "削除", "消去", "解約", "退会", "送金", "振込", "振り込",
        "設定を変更", "変更を保存", "保存", "アカウント", "ログアウト", "サインアウト", "パスワード", "リセット", "初期化",
    ]
    /// 英語は単語単位で見る（Posts や Orders のような一覧の見出しで止めすぎない）。
    private static let englishKeywords = [
        "send", "post", "buy", "purchase", "order", "pay", "delete", "remove", "erase", "unsubscribe", "transfer",
        "account", "sign out", "log out", "logout", "password", "reset", "save",
    ]
    private static let tapMethods: Set<String> = ["tap", "double_tap", "long_press", "tap_element", "find_and_tap"]
    /// ラベルが分からない座標タップや、Return での送信を確認させるアプリ。
    private static let sensitiveApps: [String] = [
        "com.apple.MobileSMS", "com.apple.mobilemail", "com.apple.Preferences", "com.apple.AppStore",
        "com.apple.Passbook", "com.apple.mobilephone", "com.apple.facetime", "jp.naver.line",
        "com.burbn.instagram", "com.atebits.Tweetie2", "com.facebook", "net.whatsapp", "com.tinyspeck",
        "jp.ne.paypay", "com.amazon", "jp.co.rakuten",
    ]
    private static let riskyURLSchemes = ["mailto:", "sms:", "tel:", "facetime:", "itms", "shortcuts:"]
    /// 承認が有効な、ツール呼び出しの回数。
    private static let approvalBudget = 3

    private struct Element {
        let label: String
        let type: String
        let frame: CGRect?
    }

    private var refs: [String: Element] = [:]
    private var recent: [Element] = []
    private var foregroundApp: String?
    private var approvalRemaining = 0

    mutating func approve() { approvalRemaining = Self.approvalBudget }
    mutating func revoke() { approvalRemaining = 0 }

    /// 結果から、ref とラベル、要素の枠、前面のアプリを覚える。
    mutating func remember(method: String, input: [String: Any], result: [String: Any]) {
        if ["launch_app", "activate_app"].contains(method), let bundle = input["bundle_id"] as? String {
            foregroundApp = bundle
        }
        for key in ["foreground_app", "bundle_id", "app"] {
            if let bundle = result[key] as? String, bundle.contains(".") { foregroundApp = bundle }
        }
        var found: [[String: Any]] = [result]
        if let items = result["items"] as? [[String: Any]] { found += items }
        if let items = result["ocr_items"] as? [[String: Any]] { found += items }
        for item in found {
            guard let label = item["label"] as? String else { continue }
            let element = Element(label: label, type: item["element_type"] as? String ?? "", frame: Self.frame(item))
            if let ref = item["ref"] as? String { refs[ref] = element }
            if element.frame != nil { recent.append(element) }
        }
        if recent.count > 200 { recent.removeFirst(recent.count - 200) }
    }

    /// 止めるべきなら理由を返す。どの呼び出しでも承認の残り回数を1つ減らす。
    mutating func blockReason(method: String, input: [String: Any]) -> String? {
        let reason = riskyTarget(method: method, input: input)
        defer { if approvalRemaining > 0 { approvalRemaining -= 1 } }
        guard let reason else { return nil }
        if approvalRemaining > 0 {
            approvalRemaining = 0
            return nil
        }
        return "Blocked: \(reason). Call \(AgentTools.confirmToolName) first, then retry only if approved."
    }

    private func riskyTarget(method: String, input: [String: Any]) -> String? {
        if method == "open_url", let url = (input["url"] as? String)?.lowercased(),
           Self.riskyURLSchemes.contains(where: { url.hasPrefix($0) }) {
            return "opening \(url) can start a message, call or purchase"
        }
        if method == "type", input["submit"] as? Bool == true, inSensitiveApp {
            return "pressing Return in \(foregroundApp ?? "this app") can send the text"
        }
        guard Self.tapMethods.contains(method) else { return nil }

        var element: Element?
        if let ref = input["ref"] as? String { element = refs[ref] }
        if element == nil, let id = input["element_id"] as? String { element = Element(label: id, type: input["element_type"] as? String ?? "", frame: nil) }
        if element == nil, let x = Self.number(input["x"]), let y = Self.number(input["y"]) {
            let point = CGPoint(x: x, y: y)
            element = recent.last(where: { $0.frame?.contains(point) == true })
        }

        guard let element else {
            // ラベルの分からない座標タップ。送信や決済をするアプリの中でだけ確認させる。
            return inSensitiveApp ? "an unlabeled tap in \(foregroundApp ?? "this app")" : nil
        }
        if element.type.lowercased() == "switch" {
            return "toggling \"\(element.label)\" changes a setting"
        }
        if Self.isRiskyLabel(element.label) {
            return "tapping \"\(element.label)\" looks like a send, purchase, delete or settings/account change"
        }
        return nil
    }

    private var inSensitiveApp: Bool {
        guard let app = foregroundApp else { return false }
        return Self.sensitiveApps.contains(where: { app.hasPrefix($0) })
    }

    static func isRiskyLabel(_ label: String) -> Bool {
        if japaneseKeywords.contains(where: { label.contains($0) }) { return true }
        let lowered = label.lowercased()
        return englishKeywords.contains { keyword in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: keyword) + "\\b"
            return lowered.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func frame(_ item: [String: Any]) -> CGRect? {
        guard let x = number(item["x"]), let y = number(item["y"]),
              let w = number(item["width"]), let h = number(item["height"]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
