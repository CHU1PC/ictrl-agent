import SwiftUI

/// 読み上げの声の設定。Gemini の API キー、モデル、声を選び、その場で試聴する。
struct VoiceSettingsView: View {
    @ObservedObject private var session = AgentSession.shared
    @State private var keyDraft = ""
    @State private var hasKey = GeminiTTS.storedKey() != nil
    @State private var model = GeminiTTS.selectedModel
    @State private var voice = GeminiTTS.selectedVoice

    private static let sample = "設定アプリを開いて、Wi-Fi の画面を表示しました。ほかに何かしますか？"

    var body: some View {
        List {
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
                    Text("▶ で試聴します。1回ごとに Gemini の料金がかかります（1回あたり 1 円未満）。")
                }
            }
        }
        .navigationTitle("声の設定")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { session.voice.stopSpeaking() }
    }

    private func preview(_ name: String) {
        guard let key = GeminiTTS.storedKey() else { return }
        session.voice.stopSpeaking()
        session.voice.speak(Self.sample, using: GeminiTTS(apiKey: key, model: model, voice: name))
    }
}
