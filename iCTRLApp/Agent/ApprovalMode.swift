import Foundation

/// エージェントの確認のしかた。
enum ApprovalMode: String, CaseIterable, Identifiable {
    case ask
    case askForPaymentsAndDeletes
    case automatic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: return "毎回聞く"
        case .askForPaymentsAndDeletes: return "支払いと削除だけ聞く"
        case .automatic: return "全部自動（Approve for me）"
        }
    }

    private static let key = "agent.approval"
    static var stored: ApprovalMode {
        get { UserDefaults.standard.string(forKey: key).flatMap(ApprovalMode.init(rawValue:)) ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// 支払いと削除に当たる言葉。「支払いと削除だけ聞く」のときに、これを含む確認だけを出す。
    private static let alwaysAsk = ["購入", "注文", "支払", "決済", "送金", "振込", "振り込", "課金", "削除", "消去", "解約", "退会",
                                    "ログアウト", "サインアウト", "初期化", "リセット",
                                    "buy", "purchase", "pay", "order", "transfer", "delete", "remove", "erase", "sign out", "log out", "reset"]

    /// この確認を人に聞くか。
    func needsUser(_ summary: String) -> Bool {
        switch self {
        case .ask: return true
        case .automatic: return false
        case .askForPaymentsAndDeletes:
            let lowered = summary.lowercased()
            return Self.alwaysAsk.contains { lowered.contains($0) }
        }
    }
}
