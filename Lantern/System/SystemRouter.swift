import Observation
import SwiftUI
import UIKit

/// Hands requests from outside a window (App Intents, Spotlight) to the window the user is in.
/// The intent sets `pending`; each `RootView` tries to `claim` it when it changes, when the window
/// becomes active and when it becomes key, and only the key window (or, before any window is
/// key, the first active one) takes it. URLs don't come through here: `onOpenURL` already
/// delivers them to one window.
@Observable
final class SystemRouter {
    static let shared = SystemRouter()

    private(set) var pending: LanternLink?

    func submit(_ link: LanternLink) { pending = link }

    /// The pending request, if this window should handle it. Taking it clears it.
    func claim(active: Bool, window: UIWindow?) -> LanternLink? {
        guard let link = pending, active else { return nil }
        let keyWindows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter(\.isKeyWindow)
        guard window?.isKeyWindow == true || keyWindows.isEmpty else { return nil }
        pending = nil
        return link
    }
}

/// Lets a SwiftUI view know which `UIWindow` it's in, for `SystemRouter.claim`.
final class WindowProbe {
    weak var window: UIWindow?
}

struct WindowReader: UIViewRepresentable {
    let probe: WindowProbe

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.probe = probe
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var probe: WindowProbe?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            probe?.window = window
        }
    }
}
