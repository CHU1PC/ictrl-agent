import SwiftUI

/// エージェントのメモ（MEMORY.md）を見て、直して、消す画面。
struct MemoryView: View {
    @State private var text = AgentMemory.load()
    @State private var saved = AgentMemory.load()
    @State private var error: String?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .padding(8)
            HStack {
                Text("\(text.count) / \(AgentMemory.maxCharacters) 字").font(.caption).foregroundColor(.secondary)
                Spacer()
                if let error { Text(error).font(.caption).foregroundColor(.orange) }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .navigationTitle("メモ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") { save(text) }.disabled(text == saved)
            }
            ToolbarItem(placement: .bottomBar) {
                Button("全部消す", role: .destructive) { confirmClear = true }
            }
        }
        .confirmationDialog("メモを全部消しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("全部消す", role: .destructive) {
                text = ""
                save("")
            }
        } message: {
            Text("エージェントが覚えたことが、次の会話から使われなくなります。元に戻せません。")
        }
    }

    private func save(_ value: String) {
        do {
            try AgentMemory.save(value)
            saved = value
            error = nil
        } catch {
            self.error = "保存できませんでした: \(error.localizedDescription)"
        }
    }
}
