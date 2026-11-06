import Foundation
import IrodoriTTS
import Network
import UIKit

/// 端末内の声（Irodori-TTS の Core ML 版）。モデルの取得と、1文ずつの合成を受け持つ。
///
/// - 声は同梱の参照音声（LocalVoiceReference.wav、落ち着いた女性の合成音声）に固定する。
/// - 読む前に Readings.json で英単語をカナに直す（Safari などを読み違えるため）。
/// - モデル（軽量INT8版、約2 GB）はアプリに同梱せず、設定画面から取得する。
/// - メモリ警告を受けたら、モデルをメモリから外す。次の文で読み込み直す。
///   バックグラウンドでは外さない。ほかのアプリを操作している間も読み上げるため。
@MainActor
final class LocalVoice: ObservableObject {
    static let shared = LocalVoice()

    enum State: Equatable {
        case notInstalled
        case downloading(String)
        case installed
        case failed(String)
    }

    enum Failure: LocalizedError {
        case missingReference
        var errorDescription: String? { "The bundled reference voice (LocalVoiceReference.wav) is missing." }
    }

    @Published private(set) var state: State

    nonisolated static let sampleRate: Double = 48_000
    private static let variant = ModelVariant.lightINT8

    private let engine = IrodoriEngine()
    private var preparation: Task<Void, Error>?
    /// 読み込みを作り直すたびに進める。失敗した古い読み込みが、新しい読み込みを消さないようにする。
    private var preparationID = 0
    private var download: Task<Void, Never>?
    /// 最後に頼んだ合成。次の合成はこれの後に始める（先読みした文の順番を守るため）。
    private var lastSynthesis: Task<Void, Never>?
    private var memoryWarning: NSObjectProtocol?

    private init() {
        state = Self.isInstalled ? .installed : .notInstalled
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.unload() }
        }
    }

    private static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalVoice", isDirectory: true)
    }

    static var modelDirectory: URL {
        rootDirectory.appendingPathComponent(variant.rawValue, isDirectory: true)
    }

    static var isInstalled: Bool { (try? ModelBundle.information(at: modelDirectory)) != nil }

    private static let readings: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Readings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }()

    // MARK: - Model

    /// 今の回線がモバイル通信など、通信量に制限のある回線かどうか。
    func isOnExpensiveNetwork() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "LocalVoice.network"))
        }
    }

    /// モデルを取得する。途中で止まっても、取得済みで検証の通ったファイルは次に使い回す。
    func startDownload() {
        guard download == nil, state != .installed else { return }
        state = .downloading("準備しています…")
        // 取得中は画面を消さない。消えるとアプリが止まり、取得も止まるため。
        UIApplication.shared.isIdleTimerDisabled = true
        // アプリを切り替えても、許される間（数十秒）は取得を続ける。時間切れなら止める。
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "LocalVoice.download") { [weak self] in
            self?.cancelDownload()
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        download = Task {
            defer {
                download = nil
                UIApplication.shared.isIdleTimerDisabled = false
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            do {
                let files = FileManager.default
                let destination = Self.modelDirectory
                try files.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)
                // 約2 GB あるので、取得途中のファイルも含めて iCloud のバックアップに載せない。
                var root = Self.rootDirectory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try root.setResourceValues(values)
                // 壊れたモデルが残っていると、取得が「既にある」で毎回失敗するので、先に消す。
                if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }

                let manifestURL = Self.variant.manifestURL
                let (data, _) = try await URLSession.shared.data(from: manifestURL)
                let sizes = try ModelBundle.manifest(from: data).files.map(\.bytes)
                let total = Double(sizes.reduce(0, +))
                try await ModelDownloader().download(manifestURL: manifestURL, to: destination) { done, count, _ in
                    let received = Double(sizes.prefix(done).reduce(0, +))
                    let text = String(format: "取得中 %.2f / %.2f GB（%d / %d ファイル）", received / 1e9, total / 1e9, done, count)
                    Task { @MainActor in
                        if case .downloading = self.state { self.state = .downloading(text) }
                    }
                }
                state = .installed
                // 取得したら、端末内の声を既定にする。
                VoiceChoice.stored = .local
                warmUp()
            } catch {
                // 止めたときは、通信中なら URLError.cancelled、ファイルの間なら CancellationError が来る。
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                state = cancelled ? .notInstalled : .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        download?.cancel()
    }

    /// モデルを消す。取得途中のファイルと、参照音声のキャッシュも消す。
    func deleteModel() async {
        // 取得と読み込みは止めても途中で抜けないことがあるので、終わるのを待ってから消す。
        cancelDownload()
        await download?.value
        await unload()
        try? await engine.clearReferenceCache()
        try? FileManager.default.removeItem(at: Self.rootDirectory)
        state = .notInstalled
        if VoiceChoice.stored == .local { VoiceChoice.stored = nil }
    }

    /// モデルをメモリから外す。読み込み中なら、終わるのを待ってから外す。
    private func unload() async {
        let pending = preparation
        preparation = nil
        preparationID += 1
        _ = try? await pending?.value
        await engine.release()
    }

    // MARK: - Synthesis

    /// モデルと参照音声を先に読み込んでおく。最初の1文で待たないようにするため。
    func warmUp() {
        guard Self.isInstalled else { return }
        Task { try? await prepare() }
    }

    /// モデルと参照音声を読み込む。読み込み中なら、その完了を待つ。
    private func prepare() async throws {
        if preparation == nil {
            let engine = self.engine
            preparationID += 1
            preparation = Task {
                try await engine.prepare(modelDirectory: Self.modelDirectory)
                // 参照音声が無いと、声を固定せずに読んでしまうので、止める。
                guard let reference = Bundle.main.url(forResource: "LocalVoiceReference", withExtension: "wav") else {
                    throw Failure.missingReference
                }
                try await engine.registerReference(reference)
            }
        }
        let id = preparationID
        do {
            try await preparation!.value
        } catch {
            // 待っていた全員が消すと、その間に作り直された読み込みまで消してしまう。
            if id == preparationID { preparation = nil }
            throw error
        }
    }

    /// 1文を合成し、48kHz、モノラル、16bit の PCM の断片を順に流す。
    /// 合成は頼んだ順に1つずつ行う。先読みした2文目が1文目より先に始まらないようにするため。
    func stream(_ text: String) -> AsyncThrowingStream<Data, Error> {
        let spoken = SpeechText.applyReadings(text, Self.readings)
        let previous = lastSynthesis
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let task = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                try await self.prepare()
                _ = try await self.engine.synthesize(spoken) { chunk in continuation.yield(chunk.pcm16) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        lastSynthesis = task
        return stream
    }
}


/// 読み上げに使う声の種類。設定画面で選ぶ。
enum VoiceChoice: String, CaseIterable, Identifiable {
    case local
    case gemini
    case system

    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "端末内の声"
        case .gemini: return "Gemini の声"
        case .system: return "iOS の声"
        }
    }

    private static let key = "agent.voice.choice"

    /// 選んだ声。nil は未選択。
    static var stored: VoiceChoice? {
        get { UserDefaults.standard.string(forKey: key).flatMap(VoiceChoice.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: key) }
    }

    /// 実際に使う声。選んだ声が使えなければ、端末内、Gemini、iOS の順に使えるものにする。
    @MainActor static var current: VoiceChoice {
        if let stored, stored.isAvailable { return stored }
        return allCases.first { $0.isAvailable } ?? .system
    }

    @MainActor var isAvailable: Bool {
        switch self {
        case .local: return LocalVoice.isInstalled
        case .gemini: return GeminiTTS.storedKey() != nil
        case .system: return true
        }
    }
}

/// 1文ずつ PCM を作る声。nil のときは iOS の声で読む。
enum VoiceSource {
    case gemini(GeminiTTS)
    case local(LocalVoice)

    /// 保存された設定で作る。iOS の声を使うときは nil。
    @MainActor static func configured() -> VoiceSource? {
        switch VoiceChoice.current {
        case .local: return .local(.shared)
        case .gemini: return GeminiTTS.configured().map(VoiceSource.gemini)
        case .system: return nil
        }
    }

    var name: String {
        switch self {
        case .gemini: return "Gemini の声"
        case .local: return "端末内の声"
        }
    }

    var sampleRate: Double {
        switch self {
        case .gemini: return GeminiTTS.sampleRate
        case .local: return LocalVoice.sampleRate
        }
    }

    @MainActor func stream(_ text: String) -> AsyncThrowingStream<Data, Error> {
        switch self {
        case .gemini(let tts): return tts.stream(text)
        case .local(let voice): return voice.stream(text)
        }
    }
}
