import SwiftUI

/// アプリを開いたときと、依頼を送る前に、動かすための前提を自動で整える。
///
/// 1. DDI が外れていれば（再起動の後など）、端末の中でマウントし直す。
/// 2. ランナーが止まっていれば、`ictrl://start` で起動する。
///
/// LocalDevVPN の接続だけは、別のアプリなので自動ではできない。そのときは案内を出す。
@MainActor
final class AppBootstrap: ObservableObject {
    static let shared = AppBootstrap()

    enum Blocker: Equatable {
        /// LocalDevVPN が切れていて、DDI をマウントできない。
        case vpnDisconnected
        /// ペアリングファイルかイメージが無く、マウントの準備が済んでいない。
        case mountNotPrepared
        case mountFailed(String)
        /// ランナーを起動できない（入っていない、など）。
        case runnerUnavailable
    }

    @Published private(set) var isPreparing = false
    @Published private(set) var blocker: Blocker?
    @Published private(set) var runnerRunning = false

    private let mounter = DDIMounter()
    private let runnerStatus = RunnerStatus(port: 8200)
    private static let runnerURL = URL(string: "ictrl://start?callback=ictrl-app://started")!
    private static let runnerStartTimeout: TimeInterval = 15

    private init() {}

    /// 前提が揃えば true。揃わなければ blocker に理由を入れて false。
    @discardableResult
    func ensureReady() async -> Bool {
        if isPreparing { return await waitForCurrent() }
        isPreparing = true
        defer { isPreparing = false }

        if await isRunnerUp() {
            blocker = nil
            return true
        }
        guard await ensureMounted() else { return false }
        guard await startRunner() else {
            blocker = .runnerUnavailable
            return false
        }
        blocker = nil
        return true
    }

    private func waitForCurrent() async -> Bool {
        while isPreparing { try? await Task.sleep(nanoseconds: 200_000_000) }
        return blocker == nil && runnerRunning
    }

    private func ensureMounted() async -> Bool {
        if DeveloperDiskImage.status().isMounted { return true }
        guard PairingFileStore.exists, DeveloperDiskImageStore.isComplete else {
            blocker = .mountNotPrepared
            return false
        }
        // 先に経路を確かめる。切れたまま試すと、原因の分かりにくい失敗になる。
        guard case .reachable = await LocalDevVPN.probeTunnel() else {
            blocker = .vpnDisconnected
            return false
        }
        await mounter.mount()
        if case .failed(let message) = mounter.phase {
            blocker = .mountFailed(message)
            return false
        }
        return DeveloperDiskImage.status().isMounted
    }

    private func startRunner() async -> Bool {
        let opened = await withCheckedContinuation { continuation in
            UIApplication.shared.open(Self.runnerURL) { continuation.resume(returning: $0) }
        }
        guard opened else { return false }
        // ランナーは起動するとこのアプリに戻ってくる。応答するまで待つ。
        let deadline = Date().addingTimeInterval(Self.runnerStartTimeout)
        while Date() < deadline {
            if await isRunnerUp() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func isRunnerUp() async -> Bool {
        await runnerStatus.check()
        runnerRunning = runnerStatus.isRunning
        return runnerRunning
    }

    /// LocalDevVPN を開く。接続して戻ってきたら、ensureReady をもう一度呼ぶ。
    func openLocalDevVPN() {
        UIApplication.shared.open(LocalDevVPN.isInstalled ? LocalDevVPN.enableURL : LocalDevVPN.appStoreURL)
    }
}

/// 前提が揃っていないときに、エージェントの画面の上に出す案内。
struct BootstrapBanner: View {
    @ObservedObject var bootstrap: AppBootstrap

    var body: some View {
        if bootstrap.isPreparing {
            HStack(spacing: 8) {
                ProgressView()
                Text("準備しています（DDI とランナーを確認中）").font(.subheadline)
            }
            .padding(10)
        } else if let blocker = bootstrap.blocker {
            VStack(alignment: .leading, spacing: 8) {
                Label(message(blocker), systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                HStack {
                    if blocker == .vpnDisconnected {
                        Button("LocalDevVPN を接続") { bootstrap.openLocalDevVPN() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("もう一度試す") { Task { await bootstrap.ensureReady() } }
                        .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
        }
    }

    private func message(_ blocker: AppBootstrap.Blocker) -> String {
        switch blocker {
        case .vpnDisconnected:
            return "再起動のあとは、LocalDevVPN の接続が必要です。接続してからこの画面に戻ってください。"
        case .mountNotPrepared:
            return "DDI をマウントする準備ができていません。歯車 → Runtime Requirements からペアリングファイルとイメージを用意してください。"
        case .mountFailed(let message):
            return "DDI をマウントできませんでした: \(message)"
        case .runnerUnavailable:
            return "iPhone Use Engine を起動できませんでした。ホーム画面のアイコンから一度起動してみてください。"
        }
    }
}
