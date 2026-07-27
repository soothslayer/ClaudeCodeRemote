import CallKit
import AVFoundation
import UIKit

// MARK: - CallManager
// CallKit integration — every conversation with Claude Code is a real system
// phone call. That buys us, for free:
//   • the native in-call UI on the lock screen (answer/mute/end, fully
//     VoiceOver accessible)
//   • the green "in call" pill / Dynamic Island treatment
//   • system-owned audio session with call-grade priority (survives
//     backgrounding without the audio hacks)
//   • hardware controls: AirPods stem mute, car kits, Bluetooth HFP routing
//
// Flow (outgoing only — Claude never cold-calls you in v1):
//   startCall() → CXStartCallAction → provider(perform:) fulfils →
//   CallKit activates the AVAudioSession → onAudioSessionActivated fires →
//   AppState starts the duplex engine + ringback + WebSocket →
//   reportConnected() when the server answers.
//
// Mute is single-sourced through CallKit: both the in-app button and the
// lock-screen button issue CXSetMutedCallAction, and the delegate callback
// (onMuteChanged) is the only place the mic actually gets muted.

@MainActor
final class CallManager: NSObject, ObservableObject {

    @Published private(set) var hasActiveCall = false

    /// Configure (but do NOT activate) the AVAudioSession — CallKit activates it.
    var onConfigureAudioSession: (() -> Void)?
    /// CallKit activated the audio session — safe to start the audio engine.
    var onAudioSessionActivated: (() -> Void)?
    /// The call ended (in-app End button, lock screen, or system teardown).
    var onCallEnded: (() -> Void)?
    /// Mute state changed (from any surface: app, lock screen, AirPods).
    var onMuteChanged: ((Bool) -> Void)?

    private let provider: CXProvider
    private let callController = CXCallController()
    private var currentCallId: UUID?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        if let icon = UIImage(systemName: "apple.terminal.fill")
            ?? UIImage(systemName: "terminal.fill") {
            config.iconTemplateImageData = icon.pngData()
        }
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    // MARK: - Public API

    /// Place the outgoing call. Returns false if CallKit refused the
    /// transaction (caller should fall back to a plain in-app conversation).
    func startCall() async -> Bool {
        guard currentCallId == nil else { return true }
        let id = UUID()
        currentCallId = id
        let handle = CXHandle(type: .generic, value: "Claude Code")
        let action = CXStartCallAction(call: id, handle: handle)
        do {
            try await requestTransaction(CXTransaction(action: action))
            return true
        } catch {
            AppLogger.shared.log("CXStartCallAction failed: \(error.localizedDescription)", tag: "CALL")
            currentCallId = nil
            return false
        }
    }

    /// The server answered — flips the system UI from "calling…" to the timer.
    func reportConnected() {
        guard let id = currentCallId else { return }
        provider.reportOutgoingCall(with: id, connectedAt: nil)
    }

    /// The server never answered — ends the call with a failure reason.
    /// Note: this does NOT round-trip through perform(CXEndCallAction), so the
    /// caller is responsible for its own teardown.
    func reportFailed() {
        guard let id = currentCallId else { return }
        provider.reportCall(with: id, endedAt: nil, reason: .failed)
        currentCallId = nil
        hasActiveCall = false
    }

    /// Hang up from inside the app. Teardown happens in perform(CXEndCallAction),
    /// which fires onCallEnded.
    func endCall() async {
        guard let id = currentCallId else { return }
        let action = CXEndCallAction(call: id)
        do {
            try await requestTransaction(CXTransaction(action: action))
        } catch {
            AppLogger.shared.log("CXEndCallAction failed: \(error.localizedDescription)", tag: "CALL")
            // CallKit lost track of the call — clean up ourselves.
            currentCallId = nil
            hasActiveCall = false
            onCallEnded?()
        }
    }

    /// Mute/unmute via CallKit so every surface (app, lock screen, AirPods)
    /// stays in sync. The actual mic change happens in onMuteChanged.
    func requestMute(_ muted: Bool) async {
        guard let id = currentCallId else { return }
        let action = CXSetMutedCallAction(call: id, muted: muted)
        try? await requestTransaction(CXTransaction(action: action))
    }

    private func requestTransaction(_ transaction: CXTransaction) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            callController.request(transaction) { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }
    }
}

// MARK: - CXProviderDelegate
// Delegate queue is .main, so MainActor.assumeIsolated is safe.

extension CallManager: CXProviderDelegate {

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            AppLogger.shared.log("provider reset", tag: "CALL")
            currentCallId = nil
            hasActiveCall = false
            onCallEnded?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            AppLogger.shared.log("perform start call", tag: "CALL")
            hasActiveCall = true
            onConfigureAudioSession?()
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            AppLogger.shared.log("perform end call", tag: "CALL")
            currentCallId = nil
            hasActiveCall = false
            onCallEnded?()
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            AppLogger.shared.log("perform mute=\(action.isMuted)", tag: "CALL")
            onMuteChanged?(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            AppLogger.shared.log("audio session activated", tag: "CALL")
            onAudioSessionActivated?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            AppLogger.shared.log("audio session deactivated", tag: "CALL")
        }
    }
}
