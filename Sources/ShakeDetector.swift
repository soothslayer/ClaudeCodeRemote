import SwiftUI
import UIKit

// MARK: - Shake-to-reset

/// Invisible UIView that sits in the responder chain and forwards shake events
/// as a SwiftUI view modifier.  Shake the phone at any time to reset to the
/// greeting flow.
class ShakeHostView: UIView {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake?() }
        super.motionEnded(motion, with: event)
    }
}

struct ShakeDetectorView: UIViewRepresentable {
    let onShake: () -> Void

    func makeUIView(context: Context) -> ShakeHostView {
        let v = ShakeHostView()
        v.onShake = onShake
        v.backgroundColor = .clear
        // Become first responder on the next run-loop tick so the view is
        // already in the hierarchy when we ask.
        DispatchQueue.main.async { v.becomeFirstResponder() }
        return v
    }

    func updateUIView(_ uiView: ShakeHostView, context: Context) {
        uiView.onShake = onShake
    }
}

// MARK: - View modifier convenience

struct OnShakeModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .background(ShakeDetectorView(onShake: action))
    }
}

extension View {
    /// Fires `action` whenever the device is shaken.
    func onShake(perform action: @escaping () -> Void) -> some View {
        modifier(OnShakeModifier(action: action))
    }
}

