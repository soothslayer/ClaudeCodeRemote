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

    /// UserDefaults key holding the AVSpeechSynthesisVoice.identifier the user
    /// picked in Settings. Nil / missing = auto-select the best installed voice.
    static let selectedVoiceIdKey = "selectedVoiceId"
    /// Set at startDuplex() to the mainMixerNode's actual output format so
    /// the player↔mixer connection needs no resampler (a mismatched format
    /// there silently stops the audio graph on some devices after VPIO is
    /// enabled).
    private var playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
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
        // .allowBluetooth (HFP) is required for the mic to route through
        // a Bluetooth headset. The symbol was renamed .allowBluetoothHFP in
        // iOS 26 and the old name deprecated, but the raw value is stable —
        // and without it, Bluetooth users get silent mic input.
        let hfp = AVAudioSession.CategoryOptions(rawValue: 1 << 2)
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothA2DP, hfp]
        )
        try session.setActive(true)

        // Enable AEC on the input node BEFORE we query mainMixerNode's
        // format or attach any player nodes. Doing this after the mixer has
        // been touched leaves the audio graph in a state that silently stops
        // when playback starts.
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            aecEnabled = true
        } catch {
            aecEnabled = false
            log.log("voice processing unavailable: \(error)", tag: "DUPLEX")
        }

        // Player node — connect using the mixer's ACTUAL format so the graph
        // needs no resampler. A hardcoded format here silently kills the
        // engine on devices whose hardware runs at a different rate.
        engine.attach(playerNode)
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        playbackFormat = mixerFormat
        engine.connect(playerNode, to: engine.mainMixerNode, format: mixerFormat)
        log.log("mixer format: \(mixerFormat)", tag: "DUPLEX")

        // Mic tap — audio thread. Guard empty buffers (they arrive when the
        // engine hiccups) so the recognizer doesn't get fed zero-length data.
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        log.log("mic tap format: \(micFormat)", tag: "DUPLEX")
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
            guard buffer.frameLength > 0 else { return }
            self?.recognitionRequest?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isDuplexRunning = true
        let inputs = session.currentRoute.inputs.map(\.portName).joined(separator: ",")
        let outputs = session.currentRoute.outputs.map(\.portName).joined(separator: ",")
        log.log("duplex started (AEC=\(aecEnabled), in=\(inputs), out=\(outputs), engineRunning=\(engine.isRunning))", tag: "DUPLEX")

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
    /// Bounded by a hard timeout so a broken audio graph can never wedge the
    /// caller — the conversation must proceed either way.
    func speakAndWait(_ text: String, timeout: TimeInterval = 12) async {
        guard isDuplexRunning else {
            await speakFallback(text)
            return
        }
        enqueueSpeech(text + "\n")
        let deadline = Date().addingTimeInterval(timeout)
        while isSpeaking || isSynthesizing || !pendingSentences.isEmpty {
            if Date() >= deadline {
                AppLogger.shared.log("speakAndWait timeout — moving on", tag: "TTS")
                flushSpeech()
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Pre-duplex speech path (permission errors before the engine can start).
    private func speakFallback(_ text: String) async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.voice = Self.preferredVoice()
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

    // MARK: - Voice selection

    /// The voice to speak with, honoring the user's Settings pick.
    /// Falls back to the best installed en-US voice (premium > enhanced >
    /// default). Recomputed on every utterance so a Settings change takes
    /// effect immediately without restarting the app.
    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: selectedVoiceIdKey),
           let picked = AVSpeechSynthesisVoice(identifier: id) {
            return picked
        }
        return bestEnglishVoice() ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Highest-quality installed English voice, preferring premium then enhanced.
    static func bestEnglishVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        return english.first(where: { $0.quality == .premium })
            ?? english.first(where: { $0.quality == .enhanced })
            ?? english.first(where: { $0.language == "en-US" })
    }

    /// All installed English voices, sorted premium → enhanced → default.
    /// Used by the Settings picker.
    static func availableEnglishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                if lhs.language != rhs.language {
                    return lhs.language < rhs.language
                }
                return lhs.name < rhs.name
            }
    }

    /// Speak a short sample using a specific voice. Used by the Settings
    /// picker so the user can hear each option before choosing. Runs
    /// independently of the duplex engine (fires even before startDuplex).
    func speakSample(_ text: String, voice: AVSpeechSynthesisVoice) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.voice = voice
        // Use plain speak() so it works whether the duplex engine is up
        // or not — the Settings sheet often opens before it is.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        synthesizer.speak(utterance)
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
        utterance.voice = Self.preferredVoice()

        let coordinator = PlaybackCoordinator(targetFormat: playbackFormat)
        coordinator.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                self?.sentenceFinished(generation: generation)
            }
        }
        currentPlayback = coordinator

        // Make sure the engine is still running before we play. Something in
        // the graph (VPIO reconfig, session interruption) can stop it between
        // startDuplex() and the first sentence; without this, playerNode.play()
        // fails silently and the coordinator never fires — the app freezes
        // "speaking" the greeting forever.
        if !engine.isRunning {
            AppLogger.shared.log("engine stopped — restarting", tag: "DUPLEX")
            do { try engine.start() } catch {
                AppLogger.shared.log("engine restart failed: \(error)", tag: "DUPLEX")
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }

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
        let log = AppLogger.shared
        guard isDuplexRunning, !isMuted else {
            log.log("cycle skipped (duplex=\(isDuplexRunning) muted=\(isMuted))", tag: "STT")
            return
        }
        guard let recognizer = speechRecognizer else {
            log.log("no recognizer for en-US", tag: "STT")
            return
        }
        guard recognizer.isAvailable else {
            log.log("recognizer not available — retrying in 1s", tag: "STT")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                Task { @MainActor [weak self] in self?.startRecognitionCycle() }
            }
            return
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        capturedSpeech = ""
        bargedInThisCycle = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognition(result: result, error: error)
            }
        }
        if recognitionTask == nil {
            log.log("recognitionTask() returned nil", tag: "STT")
        } else {
            log.log("cycle started (onDevice=\(recognizer.supportsOnDeviceRecognition))", tag: "STT")
        }
        scheduleCycleRestart()
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        guard recognitionRequest != nil else { return }   // stale callback after cycle ended

        if let result {
            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                if capturedSpeech != text {
                    AppLogger.shared.log("partial: \"\(text.prefix(60))\"", tag: "STT")
                }
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

        if let error {
            let ns = error as NSError
            AppLogger.shared.log("recognizer error \(ns.domain)/\(ns.code): \(ns.localizedDescription)", tag: "STT")
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
