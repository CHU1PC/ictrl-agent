import AVFoundation
import Speech

/// ハンズフリーの音声入出力。
///
/// マイクは会話中ずっと開けたままにする。これが UIBackgroundModes の audio と
/// 合わさって、エージェントが他のアプリを操作している間もこのアプリを生かす。
/// 読み上げ中も聞き取りは続けるが、停止語だけを受け付けて、それ以外は捨てる
/// （voiceChat のエコーキャンセルで、自分の声はほぼ拾わない）。
@MainActor
final class VoiceIO: NSObject, ObservableObject {
    enum Mode { case off, keepAlive, listening }

    @Published private(set) var mode: Mode = .off
    @Published private(set) var isSpeaking = false
    @Published private(set) var partialText = ""

    var isListening: Bool { mode == .listening }

    /// 黙ってから発話を確定するまでの秒数。
    var silenceInterval: TimeInterval = 1.4
    var stopWords: [String] = []
    var onUtterance: ((String) -> Void)?
    /// 読み上げ中に停止語が聞こえたとき。
    var onStopWord: (() -> Void)?
    /// 聞き取りを続けられなくなったとき。
    var onFailure: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let sink = BufferSink()
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var retryWork: DispatchWorkItem?
    private var pendingSpeech = 0
    /// 認識タスクの世代。閉じた古いタスクのコールバックが新しいタスクを止めないようにする。
    private var generation = 0
    private var consecutiveFailures = 0
    private static let maxFailures = 8
    private var observers: [NSObjectProtocol] = []
    private var lastRestart: Date?

    override init() {
        super.init()
        synthesizer.delegate = self
        observeAudioSession()
    }

    func requestPermissions() async -> Bool {
        let speech = await Self.requestSpeechAuthorization()
        let mic = await Self.requestMicrophone()
        return speech && mic
    }

    /// 聞き取りを始める。
    func startListening() throws {
        try startEngine()
        mode = .listening
        consecutiveFailures = 0
        beginRecognition()
    }

    /// 聞き取りはせず、音声セッションだけを開けておく。
    /// 文字で指示したときも、裏に回ったアプリを止めさせないために使う。
    func startKeepAlive() throws {
        guard mode == .off else { return }
        try startEngine()
        mode = .keepAlive
    }

    /// 聞き取りをやめる。keepAlive が要るなら、エンジンは止めずに残す。
    func stopListening(keepAlive: Bool) {
        endRecognition(emit: false, restart: false)
        if keepAlive, mode != .off {
            mode = .keepAlive
        } else {
            stopAll()
        }
    }

    func stopAll() {
        endRecognition(emit: false, restart: false)
        retryWork?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stopSpeaking()
        mode = .off
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSpeech += 1
        isSpeaking = true
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func speechEnded() {
        pendingSpeech = max(0, pendingSpeech - 1)
        guard pendingSpeech == 0 else { return }
        isSpeaking = false
    }

    // MARK: - Engine

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try Self.configureSession(session)
            try session.setActive(true)
            installTap()
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    /// voiceChat はエコーキャンセルが効くので、読み上げをマイクが拾いにくい。
    private static func configureSession(_ session: AVAudioSession) throws {
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
    }

    private func installTap() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        // 現在のハードウェアの形式で張る。出力先が変わったら張り直す。
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0),
                         block: Self.makeTapBlock(sink))
    }

    /// 音声スレッドで呼ばれるので、MainActor の隔離を持たない関数で作る。
    private nonisolated static func makeTapBlock(_ sink: BufferSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer) }
    }

    /// 割り込みや出力先の変更のあとに、今のモードのまま作り直す。
    private func restartEngine() {
        let previous = mode
        guard previous != .off else { return }
        // 作り直しそのものが設定変更の通知を呼ぶことがあるので、続けて来たものは捨てる。
        if let last = lastRestart, Date().timeIntervalSince(last) < 1 { return }
        lastRestart = Date()
        endRecognition(emit: false, restart: false)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine()
            mode = previous
            if previous == .listening { beginRecognition() }
        } catch {
            stopAll()
            onFailure?("マイクを開き直せませんでした: \(error.localizedDescription)")
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let ended = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended
            Task { @MainActor in
                guard let self, self.mode != .off else { return }
                if ended {
                    self.restartEngine()
                } else {
                    // 割り込み中は認識を閉じておく。終わったら restartEngine で戻す。
                    self.endRecognition(emit: false, restart: false)
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            // 自分の setCategory でも通知が来るので、機器の抜き差しだけを扱う。
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.restartEngine() }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartEngine() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartEngine() }
        })
    }

    // MARK: - Recognition

    private func beginRecognition() {
        guard mode == .listening, task == nil else { return }
        guard let recognizer, recognizer.isAvailable else {
            return scheduleRetry(reason: "音声認識が使えません。")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            // 端末内の認識なら、バックグラウンドでも通信に頼らず続けられる。
            request.requiresOnDeviceRecognition = true
        }
        sink.request = request
        partialText = ""
        generation += 1
        let current = generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if let result {
                    self.consecutiveFailures = 0
                    self.handle(text: result.bestTranscription.formattedString, isFinal: result.isFinal)
                } else if error != nil {
                    self.endRecognition(emit: false, restart: false)
                    self.scheduleRetry(reason: "音声認識が続けて失敗しました。")
                }
            }
        }
    }

    private func handle(text: String, isFinal: Bool) {
        if isSpeaking {
            // 読み上げ中は停止語だけを拾い、ほかは捨てる。
            if stopWords.contains(where: { text.contains($0) }) {
                stopSpeaking()
                endRecognition(emit: false, restart: true)
                onStopWord?()
            } else if isFinal {
                endRecognition(emit: false, restart: true)
            }
            return
        }
        partialText = text
        restartSilenceTimer()
        if isFinal { endRecognition(emit: true, restart: true) }
    }

    private func restartSilenceTimer() {
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: silenceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endRecognition(emit: true, restart: true) }
        }
        // スクロール中も発火させる。
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    /// 失敗が続いたら間隔を延ばして再試行し、上限に達したら止めて知らせる。
    private func scheduleRetry(reason: String) {
        guard mode == .listening else { return }
        consecutiveFailures += 1
        guard consecutiveFailures <= Self.maxFailures else {
            stopListening(keepAlive: true)
            onFailure?(reason)
            return
        }
        let delay = min(0.25 * pow(2, Double(consecutiveFailures - 1)), 8)
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.beginRecognition() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 今の認識を閉じる。emit なら確定した文を渡す。restart なら次の認識を始める。
    private func endRecognition(emit: Bool, restart: Bool) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        generation += 1
        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        sink.finish()
        task?.cancel()
        task = nil
        partialText = ""
        if emit, !text.isEmpty { onUtterance?(text) }
        if restart, mode == .listening {
            // 認識タスクは1回ごとに作り直す（1本で長く聞き続けると打ち切られる）。
            retryWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.beginRecognition() }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    // MARK: - Permissions

    private nonisolated static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    private nonisolated static func requestMicrophone() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}

extension VoiceIO: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speechEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speechEnded() }
    }
}

/// 音声スレッドから認識リクエストへバッファを渡す。
/// append と endAudio を同じロックの内側で行い、閉じたリクエストに足さない。
private final class BufferSink {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        _request?.append(buffer)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        _request?.endAudio()
        _request = nil
    }
}
