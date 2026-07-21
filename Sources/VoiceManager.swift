import AVFoundation
import Speech
import Combine

// MARK: - VoiceManager
// Full-duplex audio engine: the microphone stays live while speech plays.
//
//   • One AVAudioEngine with voice processing (echo cancellation) enabled on
//     the input node, so the mic doesn't hear our own TTS.
//   • TTS is rendered offline with AVSpeechSynthesizer.write() and played
//     through an AVAudioPlayerNode on the same engine — that keeps the echo
//     canceller's reference signal correct and makes barge-in instant
//     (playerNode.stop()).
//   • Streaming text arrives via enqueueSpeech(); it is chunked into
//     sentences and spoken as it arrives.
//   • SFSpeechRecognizer runs continuously in ~50 s cycles (Apple's task
//     limit is ~1 min). A 1.8 s silence timer endpoints each utterance.
//   • Barge-in: a real partial result while TTS is playing flushes the
//     speech queue and fires onBargeIn.

@MainActor
final class VoiceManager: NSObject, ObservableObject {

    // MARK: Published state

    @Published private(set) var isSpeaking = false      // TTS audible or queued
    @Published private(set) var isHearingUser = false   // partial results arriving
    @Published private(set) var isMuted = false
    @Published private(set) var isDuplexRunning = false

    /// A finished user utterance (after silence endpointing). Main actor.
    var onUtterance: ((String) -> Void)?
    /// The user started talking over TTS; the speech queue was just flushed.
    var onBargeIn: (() -> Void)?

    // MARK: Audio graph

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    private var aecEnabled = false

    // MARK: TTS queue

    private var deltaAccumulator = ""
    private var pendingSentences: [String] = []
    private var isSynthesizing = false
    private var speakingGeneration = 0
    private var currentPlayback: PlaybackCoordinator?
    private var inCodeBlock = false
    private var codeBlockAnnounced = false
    /// Tail of recently spoken text — used to reject mic "utterances" that are
    /// really our own TTS leaking past the echo canceller.
    private var recentlySpokenText = ""

    // MARK: STT

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var capturedSpeech = ""
    private var bargedInThisCycle = false
    private var silenceTimer: DispatchWorkItem?
    private var cycleRestartTimer: DispatchWorkItem?
    private let silenceDelay: TimeInterval = 1.8
    private let cycleLimit: TimeInterval = 50   // restart before Apple's ~60 s cap

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let log = AppLogger.shared
        log.log("requesting mic permission…", tag: "PERM")
        let micGranted: Bool
        if #available(iOS 17.0, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        log.log("mic granted=\(micGranted)", tag: "PERM")

        let speechGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        log.log("speech granted=\(speechGranted)", tag: "PERM")

        return micGranted && speechGranted
    }

    // MARK: - Duplex lifecycle

    func startDuplex() throws {
        guard !isDuplexRunning else { return }
        let log = AppLogger.shared

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothA2DP]
        )
        try session.setActive(true)

        // Echo cancellation. If unavailable we still run — barge-in then relies
        // on the echo-text rejection below.
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            aecEnabled = true
        } catch {
            aecEnabled = false
            log.log("voice processing unavailable: \(error)", tag: "DUPLEX")
        }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

        // Mic tap — audio thread. recognitionRequest is nil while muted or
        // between cycles, which safely drops the buffers.
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isDuplexRunning = true
        log.log("duplex started (AEC=\(aecEnabled), route=\(session.currentRoute.outputs.map(\.portName).joined(separator: ",")))", tag: "DUPLEX")

        startRecognitionCycle()
    }

    func stopDuplex() {
        guard isDuplexRunning else { return }
        isDuplexRunning = false
        flushSpeech()
        endRecognitionCycle(deliver: false)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Tap-to-pause: keeps the engine alive but stops feeding the recognizer.
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        if muted {
            endRecognitionCycle(deliver: false)
        } else if isDuplexRunning {
            startRecognitionCycle()
        }
    }

    // MARK: - TTS: streaming input

    /// Feed streaming text (deltas). Complete sentences are spoken as they form.
    func enqueueSpeech(_ delta: String) {
        deltaAccumulator += delta
        drainAccumulator(force: false)
        pumpSpeech()
    }

    /// Turn is over — speak whatever is still buffered.
    func finishSpeech() {
        drainAccumulator(force: true)
        pumpSpeech()
    }

    /// Drop everything queued and silence the player immediately.
    func flushSpeech() {
        speakingGeneration += 1
        pendingSentences.removeAll()
        deltaAccumulator = ""
        inCodeBlock = false
        codeBlockAnnounced = false
        currentPlayback?.invalidate()
        currentPlayback = nil
        synthesizer.stopSpeaking(at: .immediate)
        playerNode.stop()
        isSynthesizing = false
        isSpeaking = false
    }

    /// Speak a full announcement (greeting, error) and wait for it to finish.
    /// Falls back to plain AVSpeechSynthesizer if the duplex engine isn't up.
    func speakAndWait(_ text: String) async {
        guard isDuplexRunning else {
            await speakFallback(text)
            return
        }
        enqueueSpeech(text + "\n")
        while isSpeaking || isSynthesizing || !pendingSentences.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Pre-duplex speech path (permission errors before the engine can start).
    private func speakFallback(_ text: String) async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let waiter = FallbackSpeechWaiter()
        synthesizer.delegate = waiter
        synthesizer.speak(utterance)
        await waiter.wait()
        synthesizer.delegate = nil
    }

    // MARK: - TTS: sentence chunking

    /// Move complete sentences from the accumulator into pendingSentences.
    private func drainAccumulator(force: Bool) {
        // Complete lines first — a newline always ends a chunk, and this is
        // where markdown code fences are detected and skipped.
        while let nl = deltaAccumulator.firstIndex(of: "\n") {
            let line = String(deltaAccumulator[..<nl])
            deltaAccumulator = String(deltaAccumulator[deltaAccumulator.index(after: nl)...])
            acceptLine(line)
        }

        guard !inCodeBlock else { return }

        // Sentence boundaries within the trailing partial line.
        var found = true
        while found {
            found = false
            for separator in [". ", "! ", "? "] {
                if let range = deltaAccumulator.range(of: separator) {
                    let sentence = String(deltaAccumulator[..<range.upperBound])
                    deltaAccumulator = String(deltaAccumulator[range.upperBound...])
                    appendSentence(sentence)
                    found = true
                    break
                }
            }
        }

        // Very long clause with no punctuation — don't sit on it forever.
        if deltaAccumulator.count > 250 {
            appendSentence(deltaAccumulator)
            deltaAccumulator = ""
        }

        if force {
            if !deltaAccumulator.isEmpty {
                appendSentence(deltaAccumulator)
                deltaAccumulator = ""
            }
            inCodeBlock = false
            codeBlockAnnounced = false
        }
    }

    private func acceptLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            inCodeBlock.toggle()
            if inCodeBlock && !codeBlockAnnounced {
                appendSentence("Code block omitted.")
                codeBlockAnnounced = true
            }
            if !inCodeBlock { codeBlockAnnounced = false }
            return
        }
        guard !inCodeBlock else { return }
        appendSentence(line)
    }

    private func appendSentence(_ raw: String) {
        let sentence = Self.sanitizeForSpeech(raw)
        guard !sentence.isEmpty else { return }
        pendingSentences.append(sentence)
    }

    /// Strip markdown decoration that reads terribly aloud.
    static func sanitizeForSpeech(_ raw: String) -> String {
        var text = raw
        // [label](url) → label
        while let open = text.range(of: "["),
              let mid = text.range(of: "](", range: open.upperBound..<text.endIndex),
              let close = text.range(of: ")", range: mid.upperBound..<text.endIndex) {
            let label = String(text[open.upperBound..<mid.lowerBound])
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: label)
        }
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "##", with: "")
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while let first = trimmed.first, "#->*•".contains(first) {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    // MARK: - TTS: synthesis + playback

    private func pumpSpeech() {
        guard isDuplexRunning, !isSynthesizing, !pendingSentences.isEmpty else { return }
        let sentence = pendingSentences.removeFirst()
        isSynthesizing = true
        isSpeaking = true
        recentlySpokenText = String((recentlySpokenText + " " + sentence).suffix(400))
        synthesizeAndPlay(sentence, generation: speakingGeneration)
    }

    private func synthesizeAndPlay(_ text: String, generation: Int) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        let coordinator = PlaybackCoordinator(targetFormat: playbackFormat)
        coordinator.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                self?.sentenceFinished(generation: generation)
            }
        }
        currentPlayback = coordinator

        let player = playerNode
        synthesizer.write(utterance) { buffer in
            // Synthesizer callback thread — only touch the coordinator/player.
            guard coordinator.isValid, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                coordinator.synthesisComplete()
                return
            }
            guard let out = coordinator.convertIfNeeded(pcm) else { return }
            coordinator.bufferScheduled()
            player.scheduleBuffer(out, completionCallbackType: .dataPlayedBack) { _ in
                coordinator.bufferPlayed()
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func sentenceFinished(generation: Int) {
        guard generation == speakingGeneration else { return }
        isSynthesizing = false
        currentPlayback = nil
        if pendingSentences.isEmpty {
            isSpeaking = false
        } else {
            pumpSpeech()
        }
    }

    // MARK: - STT: continuous recognition cycles

    private func startRecognitionCycle() {
        guard isDuplexRunning, !isMuted,
              let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        recognitionTask?.cancel()
        recognitionTask = nil
        capturedSpeech = ""
        bargedInThisCycle = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognition(result: result, error: error)
            }
        }
        scheduleCycleRestart()
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        guard recognitionRequest != nil else { return }   // stale callback after cycle ended

        if let result {
            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                capturedSpeech = text
                isHearingUser = true
                maybeBargeIn(partial: text)
                rescheduleSilenceTimer()
            }
            if result.isFinal {
                endRecognitionCycle(deliver: true)
                return
            }
        }

        if error != nil {
            // Includes "no speech detected" (1110) after endAudio — deliver
            // whatever was captured (may be nothing) and start the next cycle.
            endRecognitionCycle(deliver: true)
        }
    }

    private func maybeBargeIn(partial: String) {
        guard isSpeaking, !bargedInThisCycle else { return }
        let words = partial.split(separator: " ").count
        let letters = partial.filter(\.isLetter).count
        guard words >= 2 || letters >= 4 else { return }        // residual-echo guard
        guard !isEchoOfSpokenText(partial) else { return }
        bargedInThisCycle = true
        AppLogger.shared.log("barge-in: \"\(partial.prefix(40))\"", tag: "DUPLEX")
        flushSpeech()
        onBargeIn?()
    }

    /// True when the mic "heard" a fragment of what we just spoke ourselves.
    private func isEchoOfSpokenText(_ text: String) -> Bool {
        let needle = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 3 else { return false }
        return recentlySpokenText.lowercased().contains(needle)
    }

    private func rescheduleSilenceTimer() {
        silenceTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.recognitionRequest?.endAudio()
            }
        }
        silenceTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceDelay, execute: item)
    }

    private func scheduleCycleRestart() {
        cycleRestartTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isDuplexRunning else { return }
                if self.capturedSpeech.isEmpty {
                    // Quiet cycle — rotate the task before Apple's ~60 s cap.
                    self.endRecognitionCycle(deliver: false)
                } else {
                    // Mid-utterance; check again shortly.
                    self.scheduleCycleRestartSoon()
                }
            }
        }
        cycleRestartTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + cycleLimit, execute: item)
    }

    private func scheduleCycleRestartSoon() {
        cycleRestartTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isDuplexRunning else { return }
                self.recognitionRequest?.endAudio()   // force endpoint; cycle restarts after delivery
            }
        }
        cycleRestartTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// Tear down the current recognition cycle, optionally delivering the
    /// captured utterance, then start the next cycle (continuous listening).
    private func endRecognitionCycle(deliver: Bool) {
        guard recognitionRequest != nil || recognitionTask != nil else { return }

        silenceTimer?.cancel()
        silenceTimer = nil
        cycleRestartTimer?.cancel()
        cycleRestartTimer = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isHearingUser = false

        let text = capturedSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        capturedSpeech = ""

        if deliver && !text.isEmpty {
            // Drop pure echo of our own TTS (only matters when AEC is weak).
            if bargedInThisCycle || !isEchoOfSpokenText(text) {
                onUtterance?(text)
            } else {
                AppLogger.shared.log("dropped echo utterance: \"\(text.prefix(40))\"", tag: "DUPLEX")
            }
        }

        if isDuplexRunning && !isMuted {
            startRecognitionCycle()
        }
    }

    // MARK: - Audio session interruptions (phone calls, Siri, …)

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        Task { @MainActor [weak self] in
            guard let self, self.isDuplexRunning else { return }
            switch type {
            case .began:
                self.flushSpeech()
                self.endRecognitionCycle(deliver: false)
            case .ended:
                try? AVAudioSession.sharedInstance().setActive(true)
                if !self.engine.isRunning {
                    try? self.engine.start()
                }
                self.startRecognitionCycle()
                AppLogger.shared.log("recovered from audio interruption", tag: "DUPLEX")
            @unknown default:
                break
            }
        }
    }
}

// MARK: - PlaybackCoordinator
// Per-sentence bridge between the synthesizer's write() callback thread and
// the player node. Tracks scheduled vs played buffers; fires onFinished once
// after synthesis is complete AND every buffer has been played back.

private final class PlaybackCoordinator: @unchecked Sendable {

    private let lock = NSLock()
    private var outstanding = 0
    private var synthDone = false
    private var finished = false
    private var valid = true
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    var onFinished: (() -> Void)?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    var isValid: Bool {
        lock.lock(); defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock(); valid = false; lock.unlock()
    }

    func bufferScheduled() {
        lock.lock(); outstanding += 1; lock.unlock()
    }

    func bufferPlayed() {
        update { self.outstanding -= 1 }
    }

    func synthesisComplete() {
        update { self.synthDone = true }
    }

    /// Convert a synthesizer buffer to the player's format (rate/channels/layout).
    func convertIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat { return buffer }
        lock.lock()
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { lock.unlock(); return nil }
        lock.unlock()

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    private func update(_ mutate: () -> Void) {
        var fire = false
        lock.lock()
        mutate()
        if valid && !finished && synthDone && outstanding == 0 {
            finished = true
            fire = true
        }
        lock.unlock()
        if fire { onFinished?() }
    }
}

// MARK: - FallbackSpeechWaiter
// Minimal delegate used only for pre-duplex announcements (permission errors).

private final class FallbackSpeechWaiter: NSObject, AVSpeechSynthesizerDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func wait() async {
        await withCheckedContinuation { cont in
            if done { cont.resume() } else { continuation = cont }
        }
    }

    private func finish() {
        done = true
        continuation?.resume()
        continuation = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish()
    }
}
