import AVFoundation
import SwiftUI

/// 読み上げの声の設定。使う声（端末内、Gemini、iOS）を選び、その場で試聴する。
struct VoiceSettingsView: View {
    /// 聞き取りの途中経過のたびに一覧を描き直さないよう、観察はしない。
    private var voiceIO: VoiceIO { AgentSession.shared.voice }
    @State private var previewed = false
    @State private var keyDraft = ""
    @State private var hasKey = GeminiTTS.storedKey() != nil
    @State private var model = GeminiTTS.selectedModel
    @State private var voice = GeminiTTS.selectedVoice
    @State private var systemRate = SpeechOutput.systemRate
    @State private var claude = AnthropicClient.Config.stored
    @State private var approval = ApprovalMode.stored
    @State private var choice = VoiceChoice.current
    @ObservedObject private var local = LocalVoice.shared
    @State private var confirmDelete = false
    @State private var confirmCellular = false

    private static let sample = "設定アプリを開いて、Wi-Fi の画面を表示しました。ほかに何かしますか？"

    var body: some View {
        List {
            Section {
                Picker("モデル", selection: $claude.model) {
                    ForEach(AnthropicClient.Model.allCases) { Text($0.title).tag($0) }
                }
                Toggle("速さ優先", isOn: $claude.fast)
            } header: {
                Text("Claude")
            } footer: {
                Text("速さ優先は、考える量を減らして返事を速くします。操作に失敗しやすいときは切ってください。変更は次の会話（「会話を消す」の後）から効きます。")
            }
            .onChange(of: claude) { _, new in AnthropicClient.Config.stored = new }

            Section {
                Picker("確認", selection: $approval) {
                    ForEach(ApprovalMode.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: approval) { _, new in ApprovalMode.stored = new }
                NavigationLink("メモ（覚えたこと）") { MemoryView() }
            } header: {
                Text("操作の確認とメモ")
            } footer: {
                Text("全部自動では、送信、購入、削除も確認なしで実行します。誤操作を止められないので、支払いのできるアプリを使うときは「支払いと削除だけ聞く」にしてください。変更は次の会話から効きます。")
            }

            Section {
                // 保存するのは、自分で選んだときだけ。モデルの削除などで表示が変わっても保存しない。
                Picker("読み上げる声", selection: Binding(get: { choice }, set: { choice = $0; VoiceChoice.stored = $0 })) {
                    ForEach(VoiceChoice.allCases.filter(\.isAvailable)) { Text($0.title).tag($0) }
                }
            } header: {
                Text("読み上げる声")
            } footer: {
                Text("使える声だけを選べます。端末内の声はモデルの取得後に、Gemini の声は API キーの保存後に選べます。読み上げに失敗した文は、iOS の声で読み上げます。")
            }

            Section {
                switch local.state {
                case .installed:
                    Label("モデルを取得済み（軽量INT8版）", systemImage: "checkmark.seal")
                    Button("端末内の声で試聴") {
                        previewed = true
                        voiceIO.stopSpeaking()
                        voiceIO.speak(Self.sample, using: .local(local))
                    }
                    Button("モデルを削除", role: .destructive) { confirmDelete = true }
                case .downloading(let progress):
                    HStack {
                        ProgressView()
                        Text(progress).padding(.leading, 8)
                    }
                    Button("取得を止める", role: .cancel) { local.cancelDownload() }
                case .notInstalled, .failed:
                    if case .failed(let message) = local.state {
                        Text("取得に失敗しました: \(message)").foregroundColor(.red)
                    }
                    Button("モデルを取得（約2 GB）") {
                        Task {
                            if await local.isOnExpensiveNetwork() { confirmCellular = true } else { local.startDownload() }
                        }
                    }
                }
            } header: {
                Text("端末内の声")
            } footer: {
                Text("通信せずに iPhone の中で読み上げます。取得には Wi-Fi で数分かかります。取得中は画面を消さずに、アプリを開いたままにしてください。大きいファイルの取得中は、表示が数分止まって見えます。途中で止まっても、もう一度押せば続きから取得します。取得が終わると、端末内の声を既定にします。")
            }
            .confirmationDialog("端末内の声のモデル（約2 GB）を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    Task {
                        await local.deleteModel()
                        choice = VoiceChoice.current
                    }
                }
            } message: {
                Text("使うには、もう一度取得が必要です。")
            }
            .confirmationDialog("モバイル通信で約2 GB を取得しますか？", isPresented: $confirmCellular, titleVisibility: .visible) {
                Button("取得する") { local.startDownload() }
            } message: {
                Text("今は Wi-Fi ではなく、通信量に制限のある回線につながっています。")
            }
            .onChange(of: local.state) { choice = VoiceChoice.current }
            .onChange(of: hasKey) { choice = VoiceChoice.current }

            Section {
                if hasKey {
                    Label("Gemini の API キーを保存済み", systemImage: "checkmark.seal")
                    Button("API キーを削除", role: .destructive) {
                        GeminiTTS.storeKey("")
                        hasKey = false
                    }
                } else {
                    SecureField("Gemini の API キー", text: $keyDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("保存") {
                        GeminiTTS.storeKey(keyDraft)
                        keyDraft = ""
                        hasKey = GeminiTTS.storedKey() != nil
                    }
                    .disabled(keyDraft.isEmpty)
                }
            } header: {
                Text("Gemini の声")
            } footer: {
                Text("キーはこの端末の Keychain にだけ保存します。")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("話す速さ")
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $systemRate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate) { editing in
                            if !editing { SpeechOutput.systemRate = systemRate }
                        }
                        Image(systemName: "hare")
                    }
                }
                Button("iOS の声で試聴") {
                    SpeechOutput.systemRate = systemRate
                    previewed = true
                    voiceIO.stopSpeaking()
                    voiceIO.speak(Self.sample, using: nil)
                }
                Button("標準の速さに戻す") {
                    systemRate = AVSpeechUtteranceDefaultSpeechRate
                    SpeechOutput.systemRate = systemRate
                }
            } header: {
                Text("iOS の声")
            } footer: {
                Text("ほかの声が使えないときも、iOS の声で読み上げます。")
            }

            Section {
                HStack {
                    Text("音声の出力先")
                    Spacer()
                    RoutePicker().frame(width: 32, height: 32)
                }
            } footer: {
                Text("AirPods、Bluetooth スピーカー、本体のスピーカー、AirPlay から選べます。")
            }

            if hasKey {
                Section("モデル") {
                    Picker("モデル", selection: $model) {
                        ForEach(GeminiTTS.Model.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: model) { _, new in GeminiTTS.selectedModel = new }
                }

                Section {
                    ForEach(GeminiTTS.voices) { item in
                        HStack {
                            Button {
                                voice = item.name
                                GeminiTTS.selectedVoice = item.name
                            } label: {
                                HStack {
                                    Image(systemName: voice == item.name ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(voice == item.name ? .accentColor : .secondary)
                                    VStack(alignment: .leading) {
                                        Text(item.name)
                                        Text(item.character).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button {
                                preview(item.name)
                            } label: {
                                Image(systemName: "play.circle")
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("声")
                } footer: {
                    Text("▶ で試聴します。試聴のたびに Gemini の料金がかかります。")
                }
            }
        }
        .navigationTitle("エージェントの設定")
        .navigationBarTitleDisplayMode(.inline)
        // 試聴したときだけ止める。エージェントの読み上げ（確認の質問など）は止めない。
        .onDisappear { if previewed { voiceIO.stopSpeaking() } }
    }

    private func preview(_ name: String) {
        guard let key = GeminiTTS.storedKey() else { return }
        previewed = true
        voiceIO.stopSpeaking()
        voiceIO.speak(Self.sample, using: .gemini(GeminiTTS(apiKey: key, model: model, voice: name)))
    }
}
