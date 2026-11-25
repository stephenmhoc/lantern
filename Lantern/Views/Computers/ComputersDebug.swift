#if DEBUG
import SwiftUI
import UIKit

/// Presented over the window a moment after launch, for screenshots without the Settings entry
/// (started from `MacLink.init`):
/// - `-ui computers`: Your Computers; `computers:bottom` also runs the test and scrolls to it.
/// - `-ui computers:empty`: removes the computer first, so the empty state.
/// - `-ui addcomputer`: the Add a Computer sheet; `addcomputer:pick` sets up the first one found.
enum ComputersDebug {
    static func presentIfAsked(_ mac: MacLink) {
        guard let ui = DebugLaunch.ui, ["computers", "computers:empty", "computers:bottom", "addcomputer", "addcomputer:pick"].contains(ui) else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if ui == "computers:empty" { mac.removeComputer() }
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene.windows.first?.rootViewController
            else { return }
            while let presented = top.presentedViewController { top = presented }
            let host = UIHostingController(rootView: Root(ui: ui).environment(mac))
            host.modalPresentationStyle = .pageSheet
            top.present(host, animated: false)
        }
    }

    private struct Root: View {
        let ui: String
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                if ui.hasPrefix("addcomputer") {
                    AddComputerView(presentation: .sheet) { dismiss() }
                } else {
                    ComputersView()
                }
            }
        }
    }
}
#endif
