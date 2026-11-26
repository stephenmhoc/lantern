#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Settings on the Mac: a window of its own (⌘, or the app menu), not a sheet over the chat, and
/// one only: showing it again brings it forward, on the page asked for. (The Mac build allows
/// more than one scene for it: the post-build script in project.yml.)
@Observable
final class SettingsWindow {
    static let shared = SettingsWindow()
    static let id = "settings"
    static let size = CGSize(width: 560, height: 640)

    var path: [SettingsPage] = []
    /// The window's scene while it's open.
    @ObservationIgnored weak var scene: UIWindowScene?

    func show(_ page: SettingsPage?, open: OpenWindowAction) {
        path = page.map { [$0] } ?? []
        if let scene, scene.activationState != .unattached {
            UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: scene.session))
        } else {
            open(id: Self.id)
        }
    }

    fileprivate func attach(_ scene: UIWindowScene) {
        self.scene = scene
        scene.title = "Settings"
        scene.sizeRestrictions?.minimumSize = Self.size
        scene.sizeRestrictions?.maximumSize = Self.size
        scene.sizeRestrictions?.allowsFullScreen = false
    }
}

struct SettingsWindowView: View {
    @State private var window = SettingsWindow.shared

    var body: some View {
        SettingsStack(path: $window.path)
            .background(SceneReader { window.attach($0) })
    }
}

/// Hands over the window scene a view ends up in.
private struct SceneReader: UIViewRepresentable {
    let found: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> Reader { Reader(found: found) }
    func updateUIView(_ view: Reader, context: Context) {}

    final class Reader: UIView {
        let found: (UIWindowScene) -> Void

        init(found: @escaping (UIWindowScene) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found(scene) }
        }
    }
}
#endif
