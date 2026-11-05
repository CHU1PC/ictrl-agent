import SwiftUI

/// 音声エージェントの画面。会話のログ、聞き取りの切り替え、確認の応答を置く。
struct AgentView: View {
    @ObservedObject private var session = AgentSession.shared
    @ObservedObject private var bootstrap = AppBootstrap.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyDraft = ""
    @State private var editingKey = false
    @State private var typed = ""

    private var voice: VoiceIO { session.voice }

    var body: some View {
        VStack(spacing: 0) {
            BootstrapBanner(bootstrap: bootstrap)
            if !session.hasAPIKey || editingKey {
                apiKeyForm
            } else if !session.runnerPaired {
                pairPrompt
            }
            transcript
            controls
        }
        .navigationTitle("iPhone Use")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                RoutePicker().frame(width: 28, height: 28)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    VoiceSettingsView()
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("会話を消す", role: .destructive) { session.clearConversation() }
                        .disabled(session.isRunning)
                    Button("Claude の API キーを変更") { editingKey = true }
                    Button("Claude の API キーを削除", role: .destructive) { session.saveAPIKey("") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        // 開いたとき、戻ってきたときに、DDI とランナーを自動で整える。
        .task { await bootstrap.ensureReady() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await bootstrap.ensureReady() } }
        }
        .alert("この操作を実行しますか？",
               isPresented: Binding(get: { session.pendingConfirmation != nil }, set: { _ in })) {
            Button("いいえ", role: .cancel) { session.answerConfirmation(false) }
            Button("はい") { session.answerConfirmation(true) }
        } message: {
            Text(session.pendingConfirmation ?? "")
        }
    }

    private var apiKeyForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude の API キー").font(.headline)
            SecureField("sk-ant-...", text: $keyDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("保存") {
                    session.saveAPIKey(keyDraft)
                    keyDraft = ""
                    editingKey = false
                }
                .disabled(keyDraft.isEmpty)
                if editingKey {
                    Button("やめる") {
                        keyDraft = ""
                        editingKey = false
                    }
                }
            }
            Text("キーはこの端末の Keychain にだけ保存します。").font(.caption).foregroundColor(.secondary)
        }
        .padding()
    }

    private var pairPrompt: some View {
        VStack(spacing: 8) {
            Text("ランナーとまだ接続していません。ランナーを起動してから押し、届いた通知で Allow を選んでください。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button {
                Task { await session.pairRunner() }
            } label: {
                if session.pairing { ProgressView() } else { Text("ランナーと接続") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.pairing)
        }
        .padding()
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            List(session.entries) { entry in
                row(entry).id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: session.entries.count) { _ in
                if let last = session.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: AgentSession.Entry) -> some View {
        switch entry.role {
        case .user:
            Text(entry.text).frame(maxWidth: .infinity, alignment: .trailing).foregroundColor(.accentColor)
        case .assistant:
            Text(entry.text)
        case .action:
            Label(entry.text, systemImage: "hand.tap").font(.caption.monospaced()).foregroundColor(.secondary)
        case .notice:
            Text(entry.text).font(.caption).foregroundColor(.secondary)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if !voice.partialText.isEmpty {
                Text(voice.partialText).font(.callout).foregroundColor(.secondary).lineLimit(2)
            }
            HStack(spacing: 12) {
                TextField("文字で指示する", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { send() }
                if session.isRunning {
                    Button(role: .destructive) { session.cancel() } label: {
                        Image(systemName: "stop.circle.fill").font(.title)
                    }
                } else {
                    Button(action: send) { Image(systemName: "paperplane.fill").font(.title2) }
                        .disabled(typed.isEmpty || !session.hasAPIKey)
                }
            }
            Button {
                if voice.isListening { session.stopVoice() } else { Task { await session.startVoice() } }
            } label: {
                Label(listenLabel, systemImage: voice.isListening ? "waveform" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(voice.isListening ? .red : .accentColor)
            .disabled(!session.hasAPIKey)
        }
        .padding()
        .background(.bar)
    }

    private var listenLabel: String {
        guard voice.isListening else { return "ハンズフリーを始める" }
        if voice.isSpeaking { return "話しています（「止めて」で中断）" }
        if session.awakeUntil != nil { return "どうぞ、指示してください" }
        return "「\(AgentSession.wakeWords[0])」と呼びかけてください（押すと止める）"
    }

    private func send() {
        session.submit(typed)
        typed = ""
    }
}
