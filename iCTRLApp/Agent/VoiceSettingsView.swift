import AVFoundation
import SwiftUI

/// 読み上げの声の設定。Gemini の API キー、モデル、声を選び、その場で試聴する。
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
            .onChange(of: claude) { AnthropicClient.Config.stored = $0 }

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
                Text("キーが無いときは iOS の声で読み上げます。キーはこの端末の Keychain にだけ保存します。")
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
                Text("Gemini の API キーが無いときは、iOS の声で読み上げます。")
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
                    .onChange(of: model) { GeminiTTS.selectedModel = $0 }
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
        voiceIO.speak(Self.sample, using: GeminiTTS(apiKey: key, model: model, voice: name))
    }
}
