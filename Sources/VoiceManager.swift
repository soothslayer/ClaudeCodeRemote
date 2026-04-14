import AVFoundation
import Speech
import Combine

// MARK: - VoiceManager
// Handles all Text-to-Speech (TTS) and Speech-to-Text (STT).
// @MainActor — all public methods must be called from the main actor.

@MainActor
final class VoiceManager: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false
    @Published private(set) var isListening = false

    // TTS
    private let synthesizer = AVSpeechSynthesizer()
    private var speakContinuation: CheckedContinuation<Void, Never>?

    // STT
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let audioEngine = AVAudioEngine()
    private var listenContinuation: CheckedContinuation<String?, Never>?
    private var silenceTimer: DispatchWorkItem?
    private let silenceDelay: TimeInterval = 1.8
    private var capturedSpeech = ""

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
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

        let speechGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }

        return micGranted && speechGranted
    }

    // MARK: - TTS

    func speak(_ text: String) async {
        // Stop any active listening before speaking
        stopListeningInternal()

        activateAudioForPlayback()

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }

        isSpeaking = true

        await withCheckedContinuation { [weak self] (continuation: CheckedContinuation<Void, Never>) in
            guard let self else {
                continuation.resume()
                return
            }
            speakContinuation = continuation
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = 0.5
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            synthesizer.speak(utterance)
        }

        isSpeaking = false
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
            // Delegate will resume the continuation
        }
    }

    /// Pause mid-utterance. The async speak() continuation stays alive.
    func pauseSpeaking() {
        synthesizer.pauseSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Resume a paused utterance.
    func resumeSpeaking() {
        synthesizer.continueSpeaking()
        isSpeaking = true
    }

    // MARK: - STT

    /// Listen until the user stops speaking (silence detection) or 30s max.
    /// Returns the transcribed text, or nil if nothing was captured.
    func listen() async -> String? {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            return nil
        }
        stopListeningInternal()
        activateAudioForRecording()

        isListening = true
        capturedSpeech = ""

        return await withCheckedContinuation { [weak self] (continuation: CheckedContinuation<String?, Never>) in
            guard let self else {
                continuation.resume(returning: nil)
                return
            }
            listenContinuation = continuation
            startAudioCapture(recognizer: recognizer)
        }
    }

    /// Stop listening early and submit whatever was heard (e.g. user taps during capture).
    func stopListening() {
        recognitionRequest?.endAudio()
    }

    // MARK: - Private audio helpers

    private func activateAudioForPlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
    }

    private func activateAudioForRecording() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startAudioCapture(recognizer: SFSpeechRecognizer) {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            finishListening(text: nil)
            return
        }
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            finishListening(text: nil)
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty { self.capturedSpeech = text }

                if result.isFinal {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.finishListening(text: self.capturedSpeech.isEmpty ? nil : self.capturedSpeech)
                    }
                    return
                }

                // Silence detection: restart timer on each partial result
                self.silenceTimer?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.recognitionRequest?.endAudio()
                    }
                }
                self.silenceTimer = item
                DispatchQueue.main.asyncAfter(deadline: .now() + self.silenceDelay, execute: item)
            }

            if let error = error {
                // Ignore "no speech detected" errors — return whatever we captured
                let nsError = error as NSError
                let isSilence = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
                let captured = self.capturedSpeech
                Task { @MainActor [weak self] in
                    self?.finishListening(text: (captured.isEmpty || isSilence) ? nil : captured)
                }
            }
        }

        // Hard timeout: 30 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                self.recognitionRequest?.endAudio()
            }
        }
    }

    private func finishListening(text: String?) {
        guard isListening else { return }   // Prevent double-firing
        isListening = false
        capturedSpeech = ""

        silenceTimer?.cancel()
        silenceTimer = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        listenContinuation?.resume(returning: text)
        listenContinuation = nil
    }

    private func stopListeningInternal() {
        if isListening { finishListening(text: nil) }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speakContinuation?.resume()
            self?.speakContinuation = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speakContinuation?.resume()
            self?.speakContinuation = nil
        }
    }
}
