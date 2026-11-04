import Combine
import Foundation
import UIKit

/// 会話とエージェントの往復を持つ。Claude が返したツール呼び出しを、
/// 同じ端末のランナーへ RPC で流す。
///
/// アプリ全体で1つだけ作る。画面を出入りしてもマイクを二重に開かず、
/// 裏で動いているエージェントにも戻ってこられる。
///
/// 会話の履歴は追記だけにする。Sonnet 5.5 は思考ブロックを会話に紐づけて
/// 検証するので、過去の手番を書き換えると思考が無効になる。
@MainActor
final class AgentSession: ObservableObject {
    static let shared = AgentSession()

    struct Entry: Identifiable {
        enum Role { case user, assistant, action, notice, error }
        let id = UUID()
        let role: Role
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isRunning = false
    @Published private(set) var pendingConfirmation: String?
    @Published private(set) var hasAPIKey = AnthropicClient.storedKey() != nil
    @Published private(set) var runnerPaired = false
    @Published private(set) var pairing = false
    /// 起動語のあと、次の発話を起動語なしで受け付ける期限。
    @Published private(set) var awakeUntil: Date?

    let voice = VoiceIO()

    static let wakeWords = ["ジャービス", "じゃーびす", "Jarvis", "jarvis", "JARVIS"]
    private static let awakeWindow: TimeInterval = 10
    private static let maxSteps = 60
    private static let stopWords = ["止めて", "とめて", "ストップ", "やめて", "中止"]

    private var messages: [[String: Any]] = []
    private var runner = RunnerClient(port: 8200)
    private var guardrail = RiskGuard()
    private var loopTask: Task<Void, Never>?
    private var confirmation: CheckedContinuation<Bool, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private lazy var tools = AgentTools.definitions
    private lazy var system = Self.makeSystemPrompt()
    private var voiceChanges: AnyCancellable?

    private init() {
        runnerPaired = runner.isPaired
        voice.stopWords = Self.stopWords
        voice.onUtterance = { [weak self] text in self?.handleUtterance(text) }
        voice.onStopWord = { [weak self] in self?.handleStopWord() }
        voice.onFailure = { [weak self] message in self?.fail(message, spoken: message) }
        voice.onNotice = { [weak self] message in self?.noteOnce(message) }
        // 画面は session だけを見るので、音声の状態の変化もここから流す。
        voiceChanges = voice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: - Settings

    func saveAPIKey(_ key: String) {
        AnthropicClient.storeKey(key)
        hasAPIKey = AnthropicClient.storedKey() != nil
    }

    func pairRunner() async {
        pairing = true
        defer { pairing = false }
        refreshRunner()
        if runnerPaired { return }
        do {
            try await runner.pair()
            runnerPaired = true
            note("ランナーと接続しました。")
        } catch {
            fail("ランナーと接続できませんでした: \(error.localizedDescription)", spoken: "ランナーと接続できませんでした。")
        }
    }

    /// 設定画面など、別の RunnerClient で接続した結果を拾い直す。
    private func refreshRunner() {
        if !runner.isPaired { runner = RunnerClient(port: 8200) }
        runnerPaired = runner.isPaired
    }

    func startVoice() async {
        guard await voice.requestPermissions() else {
            fail("マイクと音声認識の許可が必要です。設定アプリで許可してください。", spoken: "マイクと音声認識の許可が必要です。")
            return
        }
        do {
            try voice.startListening()
            note("聞き取りを始めました。「\(Self.wakeWords[0])」と呼びかけてから指示してください。")
        } catch {
            fail("マイクを開けませんでした: \(error.localizedDescription)", spoken: "マイクを開けませんでした。")
        }
    }

    func stopVoice() {
        voice.stopListening(keepAlive: isRunning)
        awakeUntil = nil
    }

    // MARK: - Input

    func handleUtterance(_ text: String) {
        if pendingConfirmation != nil {
            switch Self.interpretAnswer(text) {
            case .some(let approved): answerConfirmation(approved)
            case .none: voice.speak("はいか、いいえで答えてください。")
            }
            return
        }
        if isRunning {
            if Self.stopWords.contains(where: { text.contains($0) }) { cancel() }
            return
        }
        // 起動語が無い発話は、周りの会話やテレビの音として捨てる。
        if let range = Self.wakeWords.lazy.compactMap({ text.range(of: $0) }).first {
            let rest = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if rest.isEmpty {
                awakeUntil = Date().addingTimeInterval(Self.awakeWindow)
                voice.speak("はい、どうぞ。")
            } else {
                submit(rest)
            }
            return
        }
        if let until = awakeUntil, Date() < until {
            submit(text)
        }
    }

    private func handleStopWord() {
        if isRunning { cancel() }
    }

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        awakeUntil = nil
        guard let key = AnthropicClient.storedKey() else {
            fail("Claude の API キーを設定してください。", spoken: "API キーを設定してください。")
            return
        }
        refreshRunner()
        guard runnerPaired else {
            fail("ランナーと接続していません。「ランナーと接続」を押してください。", spoken: "ランナーと接続していません。")
            return
        }
        // 前の依頼で使われなかった承認は、新しい依頼に持ち越さない。
        guardrail.revoke()
        // ループの開始を待たずに印を立てる。その間に来た発話で2本目を走らせない。
        isRunning = true
        entries.append(Entry(role: .user, text: trimmed))
        messages.append(["role": "user", "content": trimmed])
        let client = AnthropicClient(apiKey: key)
        loopTask = Task { await self.run(client: client) }
    }

    func answerConfirmation(_ approved: Bool) {
        guard let confirmation else { return }
        self.confirmation = nil
        pendingConfirmation = nil
        entries.append(Entry(role: .user, text: approved ? "承認" : "拒否"))
        confirmation.resume(returning: approved)
    }

    func cancel() {
        loopTask?.cancel()
        answerConfirmation(false)
        voice.stopSpeaking()
    }

    func clearConversation() {
        guard !isRunning else { return }
        messages.removeAll()
        entries.removeAll()
        guardrail = RiskGuard()
    }

    /// 確認への答えを読む。否定を含めば必ず拒否、肯定は短い発話に限る。分からなければ nil。
    static func interpretAnswer(_ text: String) -> Bool? {
        let t = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let negations = ["ない", "ません", "いいえ", "いや", "だめ", "ダメ", "やめ", "止め", "とめ", "待って", "まって",
                         "ストップ", "キャンセル", "ノー", "no", "中止", "結構"]
        if negations.contains(where: { t.contains($0) }) { return false }
        guard t.count <= 12 else { return nil }
        let affirmations = ["はい", "いいよ", "お願い", "おねがい", "オッケー", "ok", "うん", "どうぞ", "yes", "実行して", "進めて", "やって"]
        return affirmations.contains(where: { t.contains($0) }) ? true : nil
    }

    // MARK: - Agent loop

    private func run(client: AnthropicClient) async {
        beginKeepAlive()
        defer {
            isRunning = false
            endKeepAlive()
        }

        for _ in 0..<Self.maxSteps {
            if Task.isCancelled { return stopped() }
            let response: [String: Any]
            do {
                response = try await client.send(system: system, tools: tools, messages: messages)
            } catch {
                if Task.isCancelled { return stopped() }
                let spoken = (error as? AnthropicClient.Failure)?.spokenText ?? "Claude へのリクエストが失敗しました。"
                return fail(error.localizedDescription, spoken: spoken)
            }

            let content = response["content"] as? [[String: Any]] ?? []
            let stopReason = response["stop_reason"] as? String ?? ""
            if stopReason == "refusal" {
                return fail("Claude がこの依頼を断りました。", spoken: "Claude がこの依頼を断りました。")
            }
            // 思考ブロックも含めて、返ってきた content をそのまま履歴に足す。
            messages.append(["role": "assistant", "content": content])

            for block in content where block["type"] as? String == "text" {
                if let text = block["text"] as? String, !text.isEmpty {
                    entries.append(Entry(role: .assistant, text: text))
                    voice.speak(text)
                }
            }

            let toolUses = content.filter { $0["type"] as? String == "tool_use" }
            if stopReason == "tool_use" {
                var results: [[String: Any]] = []
                for block in toolUses {
                    let id = block["id"] as? String ?? ""
                    if Task.isCancelled {
                        results.append(toolResult(id: id, text: "Cancelled by the user.", isError: true))
                        continue
                    }
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    results.append(await execute(id: id, name: name, input: input))
                }
                // tool_use には必ず tool_result を返す。中断時もここで閉じてから抜ける。
                messages.append(["role": "user", "content": results])
                if Task.isCancelled { return stopped() }
                continue
            }

            // 途中で切れた応答に tool_use が残っていれば、ここで閉じる。閉じないと次の送信が 400 になる。
            if !toolUses.isEmpty {
                let reason = stopReason == "max_tokens" ? "Not executed: your output was cut off by max_tokens." : "Not executed."
                messages.append(["role": "user", "content": toolUses.map { toolResult(id: $0["id"] as? String ?? "", text: reason, isError: true) }])
            }
            switch stopReason {
            case "pause_turn":
                continue
            case "max_tokens":
                return fail("応答が長すぎて途中で切れました。", spoken: "応答が長すぎて途中で切れました。")
            default:
                return
            }
        }
        fail("手順が\(Self.maxSteps)回を超えたので止めました。", spoken: "手順が多すぎるので止めました。")
    }

    private func execute(id: String, name: String, input: [String: Any]) async -> [String: Any] {
        if name == AgentTools.confirmToolName {
            let summary = input["summary"] as? String ?? "この操作"
            let approved = await askConfirmation(summary)
            if approved { guardrail.approve() } else { guardrail.revoke() }
            return toolResult(id: id, text: AgentTools.jsonText(["approved": approved]), isError: false)
        }
        if let reason = guardrail.blockReason(method: name, input: input) {
            entries.append(Entry(role: .notice, text: "確認なしの危険な操作を止めました"))
            return toolResult(id: id, text: reason, isError: true)
        }
        let prepared = AgentTools.prepare(method: name, input: input)
        entries.append(Entry(role: .action, text: Self.describe(name, prepared)))
        do {
            let result = try await runner.call(name, prepared, timeout: 40)
            guardrail.remember(method: name, input: prepared, result: result)
            return ["type": "tool_result", "tool_use_id": id, "content": AgentTools.resultContent(for: result)]
        } catch {
            if let failure = error as? RunnerClient.Failure, failure == .notPaired || failure == .keyRejected {
                // 接続が切れたら、同じエラーを手順の上限まで繰り返さずに止める。
                runnerPaired = false
                loopTask?.cancel()
            }
            return toolResult(id: id, text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private func askConfirmation(_ summary: String) async -> Bool {
        pendingConfirmation = summary
        voice.speak("\(summary) 実行してよいですか？")
        return await withCheckedContinuation { continuation in
            if Task.isCancelled {
                pendingConfirmation = nil
                continuation.resume(returning: false)
            } else {
                confirmation = continuation
            }
        }
    }

    // MARK: - Staying alive in the background

    /// 実行中は、聞き取りをしていなくても音声セッションを開けておく。
    /// エージェントが他のアプリを操作してこのアプリが裏に回っても、止められないようにするため。
    private func beginKeepAlive() {
        if voice.mode == .off {
            do {
                try voice.startKeepAlive()
            } catch {
                note("裏で動かし続けるための音声セッションを開けませんでした。操作中に止まることがあります。")
            }
        }
        // 音声セッションが開けなかったときの保険。数十秒しかもたない。
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "agent-run") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endKeepAlive() {
        if voice.mode == .keepAlive { voice.stopAll() }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Helpers

    private func toolResult(id: String, text: String, isError: Bool) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": text, "is_error": isError]
    }

    private func stopped() {
        note("止めました。")
        voice.speak("止めました。")
    }

    private func note(_ text: String) {
        entries.append(Entry(role: .notice, text: text))
    }

    /// 同じ知らせを、直前と続けて出さない（読み上げの失敗が文ごとに並ばないように）。
    private func noteOnce(_ text: String) {
        if entries.last?.text == text { return }
        note(text)
    }

    /// 画面には詳細を、声には短い日本語を出す。
    private func fail(_ detail: String, spoken: String) {
        entries.append(Entry(role: .error, text: detail))
        voice.speak(spoken)
        ictrlLog("Agent: \(detail)")
    }

    private static func describe(_ name: String, _ input: [String: Any]) -> String {
        let shown = input.filter { !["settle", "settle_timeout", "fast"].contains($0.key) }
        guard !shown.isEmpty else { return name }
        let args = shown.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(name) \(args)"
    }

    // MARK: - System prompt

    private static let agentInstructions = """
    You are a voice assistant that operates this iPhone for the user through the iCTRL tools. \
    The user speaks Japanese, and every text you write is read aloud. Reply in Japanese, in one or two short spoken sentences, with no markdown, lists, or URLs.

    Call device_info once at the start of a task. Speak only at meaningful milestones, not before every tool call. \
    To see the screen, prefer page_source with visible_only true or find_element; use screenshot only when the tree is missing what you need.

    Before any action that sends or posts a message, makes a purchase or payment, deletes data, or changes a setting or account, call confirm_with_user with one sentence saying exactly what will happen, and continue only if it returns approved true. \
    An approval covers only the next few actions, so perform the approved action right away. \
    If a tool result says Blocked, call confirm_with_user before trying again. \
    Never type passwords, passcodes, or payment details; ask the user to enter them by hand. \
    If the request is ambiguous, ask the user instead of guessing. When the task is done, say so in one sentence.

    The iCTRL operating manual follows. It is written for clients that call the HTTP API from a shell. \
    You call the same methods directly as tools, so ignore its instructions about curl, shells, files, grep, the $I helper, pairing, envelopes, tickets, updating the skill, and the config, reset, logs and stream_ticket methods.
    """

    private static func makeSystemPrompt() -> [[String: Any]] {
        var text = agentInstructions
        if let url = Bundle.main.url(forResource: "SKILL", withExtension: "md"),
           let manual = try? String(contentsOf: url, encoding: .utf8) {
            text += "\n\n" + manual
        }
        return [["type": "text", "text": text]]
    }
}
