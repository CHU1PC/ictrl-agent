import AVFoundation

/// 読み上げ。文ごとに Gemini から PCM をストリーミングで受け取り、1つの再生ノードに順に積む。
///
/// - 先に頼むのは、再生中の文と次の数文だけにする（長い返事で利用上限に当たらないように）。
/// - 前の文を受け取り終えたら、すぐ次の文を同じノードに積むので、文の間に隙間ができない。
/// - 音が1つも届かなかった文は、iOS の声で読む。
/// - isSpeaking は、実際に音を出している間だけ true にする。
@MainActor
final class SpeechOutput: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    /// Gemini の声を使えなかったときなどの知らせ。
    var onNotice: ((String) -> Void)?
    /// 再生の前に呼ぶ。聞き取りをしていないときは、ここで音声セッションを開いてもらう。
    var prepareSession: (() throws -> Void)?
    /// 読み上げがすべて終わったとき、または止めたとき。
    var onIdle: (() -> Void)?
    /// 文ごとの時間の計測結果（遅さの切り分け用）。
    var onTiming: ((String) -> Void)?

    /// 再生中の文に加えて、先に頼んでおく文の数。
    private static let lookahead = 2

    private final class Job {
        let text: String
        let tts: GeminiTTS?
        private(set) var stream: AsyncThrowingStream<Data, Error>?
        /// Gemini に頼んだ時刻。
        private(set) var requestedAt: Date?

        init(text: String, tts: GeminiTTS?) {
            self.text = text
            self.tts = tts
        }

        func start() {
            if stream == nil, let tts {
                requestedAt = Date()
                stream = tts.stream(text)
            }
        }
    }

    private enum Outcome {
        case played
        case failedBeforeAudio(Error)
        case failedMidway(Error)
    }

    private var queue: [Job] = []
    private var loopTask: Task<Void, Never>?
    /// 止めるたびに進める。古いループや遅れて届いた通知を見分ける。
    private var generation = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: GeminiTTS.sampleRate, channels: 1, interleaved: false)!
    private var connected = false
    /// 積んだがまだ鳴らし終えていない断片の数。エンジンが作り直されたら、その時点の分は捨てる。
    private var pendingBuffers = 0
    private var bufferEpoch = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    private let synthesizer = AVSpeechSynthesizer()
    private var systemSpeech: (utterance: AVSpeechUtterance, continuation: CheckedContinuation<Void, Never>)?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        synthesizer.delegate = self
        observe()
    }

    func speak(_ text: String, using tts: GeminiTTS?) {
        for sentence in SpeechText.sentences(text) {
            queue.append(Job(text: sentence, tts: tts))
        }
        prefetch()
        if loopTask == nil {
            let generation = self.generation
            loopTask = Task { await self.run(generation) }
        }
    }

    func stop() {
        generation += 1
        loopTask?.cancel()
        loopTask = nil
        // 捨てたジョブのストリームが解放されると、その通信も止まる。
        queue.removeAll()
        discardScheduledBuffers()
        player.stop()
        synthesizer.stopSpeaking(at: .immediate)
        finishSystemSpeech()
        stopEngine()
        isSpeaking = false
        onIdle?()
    }

    private func prefetch() {
        for job in queue.prefix(Self.lookahead + 1) { job.start() }
    }

    // MARK: - Loop

    private func run(_ generation: Int) async {
        while generation == self.generation {
            while generation == self.generation, !queue.isEmpty {
                let job = queue.removeFirst()
                job.start()
                prefetch()
                if let stream = job.stream {
                    switch await play(stream, job: job, generation: generation) {
                    case .played:
                        break
                    case .failedBeforeAudio(let error):
                        guard generation == self.generation else { return }
                        onNotice?("Gemini の声を使えなかったので、iOS の声で読み上げます: \(error.localizedDescription)")
                        await drain()
                        await speakWithSystemVoice(job.text)
                    case .failedMidway(let error):
                        onNotice?("Gemini の読み上げが途中で切れました: \(error.localizedDescription)")
                    }
                } else {
                    await drain()
                    await speakWithSystemVoice(job.text)
                }
            }
            await drain()
            // 待っている間に次の文が足されていれば、続けて読む。
            if queue.isEmpty { break }
        }
        guard generation == self.generation else { return }
        loopTask = nil
        isSpeaking = false
        stopEngine()
        onIdle?()
    }

    private func play(_ stream: AsyncThrowingStream<Data, Error>, job: Job, generation: Int) async -> Outcome {
        var decoder = PCMDecoder()
        var played = false
        let turn = Date()
        var firstChunk: Date?
        var sampleCount = 0
        do {
            for try await chunk in stream {
                guard generation == self.generation else { return .played }
                if firstChunk == nil { firstChunk = Date() }
                let samples = decoder.samples(chunk)
                sampleCount += samples.count
                if !samples.isEmpty, schedule(samples) { played = true }
            }
            if let requested = job.requestedAt, let first = firstChunk {
                // 受信が音声の長さより長ければ、生成が再生に追いつかず、途中で音が途切れている。
                let audio = Double(sampleCount) / GeminiTTS.sampleRate
                let waited = max(0, first.timeIntervalSince(turn))
                onTiming?(String(format: "声: 最初の音まで %.1f秒（順番が来てから %.1f秒待ち）、受信 %.1f秒 / 音声 %.1f秒「%@」",
                                 first.timeIntervalSince(requested), waited, Date().timeIntervalSince(requested), audio,
                                 String(job.text.prefix(12))))
            }
            return played ? .played : .failedBeforeAudio(GeminiTTS.Failure.noAudio)
        } catch {
            return played ? .failedMidway(error) : .failedBeforeAudio(error)
        }
    }

    // MARK: - Playback

    private func schedule(_ samples: [Float]) -> Bool {
        do {
            try startEngine()
        } catch {
            onNotice?("音声を再生できませんでした: \(error.localizedDescription)")
            return false
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return false }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        pendingBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack,
                              completionHandler: Self.completion(for: self, epoch: bufferEpoch))
        if !player.isPlaying { player.play() }
        isSpeaking = true
        return true
    }

    /// 再生スレッドで呼ばれるので、MainActor の隔離を持たない関数で作る。
    private nonisolated static func completion(for owner: SpeechOutput, epoch: Int) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { @Sendable [weak owner] _ in
            Task { @MainActor in owner?.bufferPlayed(epoch: epoch) }
        }
    }

    private func bufferPlayed(epoch: Int) {
        guard epoch == bufferEpoch else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        if pendingBuffers == 0 { resumeDrainWaiters() }
    }

    /// 積んだ断片を鳴らし終えるまで待つ。
    private func drain() async {
        guard pendingBuffers > 0 else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// 積んだ断片の完了通知を、もう待たない（止めたとき、エンジンが作り直されたとき）。
    private func discardScheduledBuffers() {
        bufferEpoch += 1
        pendingBuffers = 0
        resumeDrainWaiters()
    }

    private func startEngine() throws {
        if engine.isRunning { return }
        try prepareSession?()
        if !connected {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connected = true
        }
        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        player.stop()
        engine.stop()
    }

    private func observe() {
        let center = NotificationCenter.default
        // 出力先の切り替えや割り込みでエンジンが止まると、積んだ断片の完了通知が来なくなる。
        // その分は捨てて、残りの断片を積むときにエンジンを起こし直す。
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.discardScheduledBuffers()
                self.player.stop()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            // 電話などに割り込まれたら、読み上げはやめる。
            Task { @MainActor in self?.stop() }
        })
    }

    // MARK: - System voice

    private static let systemRateKey = "agent.system.rate"

    /// iOS の声の話す速さ（AVSpeechUtterance の rate。0 が最も遅く、1 が最も速い）。
    static var systemRate: Float {
        get {
            let stored = UserDefaults.standard.object(forKey: systemRateKey) as? Float
            return stored ?? AVSpeechUtteranceDefaultSpeechRate
        }
        set { UserDefaults.standard.set(newValue, forKey: systemRateKey) }
    }

    private func speakWithSystemVoice(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.rate = Self.systemRate
        isSpeaking = true
        await withCheckedContinuation { continuation in
            systemSpeech = (utterance, continuation)
            synthesizer.speak(utterance)
        }
    }

    /// 終わった発話が待っているものと同じときだけ進める。止めた直後の古い通知では進めない。
    private func systemSpeechEnded(_ utterance: AVSpeechUtterance) {
        guard systemSpeech?.utterance === utterance else { return }
        finishSystemSpeech()
    }

    private func finishSystemSpeech() {
        let pending = systemSpeech
        systemSpeech = nil
        pending?.continuation.resume()
    }
}

extension SpeechOutput: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.systemSpeechEnded(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.systemSpeechEnded(utterance) }
    }
}
