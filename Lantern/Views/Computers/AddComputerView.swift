import SwiftUI
import UIKit

/// Pairing with Lantern on a Mac, whose bridge serves Inkling to paired devices, encrypted.
/// "Pair a Device" on the Mac shows a QR code for the camera (or a link to paste) and a code to
/// type here, which is tried with the Macs found on this network. It's Settings › Mac until a Mac
/// is paired.
struct AddComputerView: View {
    @Environment(MacLink.self) private var mac
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var browser = BridgeBrowser()
    @State private var pairing: PairingSheet.Request?
    @State private var pasteProblem: String?
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 88, height: 88)
                        .background(.tint.opacity(colorScheme == .dark ? 0.18 : 0.12), in: .circle)
                        .accessibilityHidden(true)
                    Text(Device.isMac ? "Pair with a Mac" : "Pair Your Mac").font(.title.bold())
                    Text(Device.isMac
                         ? "Use Inkling on the Mac that serves it: at home on your own network, or anywhere over your tailnet. Encrypted all the way."
                         : "Use your Mac's larger model from this \(Device.name): at home on your own network, or anywhere over your tailnet. Encrypted all the way.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
            }

            Section {
                step(1, Device.isMac ? "Open Lantern on the Mac that serves Inkling." : "Open Lantern on your Mac.")
                step(2, "In its Settings, choose \u{201C}Pair a Device…\u{201D}")
                step(3, Device.isMac ? "Type the code it shows below."
                     : "Point this \(Device.name)'s camera at the QR code, or type the code below.")
            } footer: {
                Text("Pairing is one time. The code only works for ten minutes.")
            }

            Section {
                HStack(spacing: 12) {
                    TextField("Code", text: $code, prompt: Text(verbatim: "ABCD-EFGH"))
                        .font(.title3.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($codeFocused)
                        .submitLabel(.go)
                        .onSubmit(pairWithCode)
                    Button("Pair", action: pairWithCode)
                        .buttonStyle(.borderedProminent)
                        .disabled(MacPairing.normalizedCode(code) == nil)
                }
            } header: {
                Text("Enter Code")
            } footer: {
                Text("Works on your home network, with the Mac listed below.")
            }

            Section {
                Button("Paste a Pairing Link", systemImage: "doc.on.clipboard", action: paste)
            } footer: {
                if let pasteProblem {
                    Label(pasteProblem, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                } else {
                    Text("The link comes from \u{201C}Copy Link\u{201D} or \u{201C}Send…\u{201D} under the QR code on the Mac.")
                }
            }

            Section {
                ForEach(browser.found) { found in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(found.name)
                            Text(found.fingerprint == nil ? "Running an older Lantern: pair with its QR code."
                                 : "Serving Inkling. Enter the code it shows to pair.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "desktopcomputer")
                    }
                }
                if browser.found.isEmpty {
                    if let problem = browser.problem {
                        Text(problem).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for Macs running Lantern…").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("On This Network")
            }

            tailnetSection
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .onChange(of: mac.tailnet.state) { _, state in
            if case .needsLogin(let url) = state { openURL(url) }
        }
        .sheet(item: $pairing) { request in
            switch request {
            case .link(let offer): PairingSheet(offer: offer)
            case .code(let code, let bridges): PairingSheet(code: code, bridges: bridges)
            }
        }
    }

    /// Lantern's own tailnet node, for reaching the Mac away from home without the Tailscale app.
    /// Pairing joins it with the Mac's key when the Mac has Tailscale set up; signing in here is
    /// the way otherwise.
    @ViewBuilder private var tailnetSection: some View {
        Section {
            switch mac.tailnet.state {
            case .connected:
                Label {
                    Text("Signed In to Tailscale")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .signedOut, .failed:
                Button("Sign In with Tailscale") { Task { await mac.tailnet.signIn() } }
            case .needsLogin(let url):
                Button("Open Tailscale Sign-In") { openURL(url) }
            case .starting:
                HStack(spacing: 10) { ProgressView(); Text("Connecting to your tailnet…").foregroundStyle(.secondary) }
            case .unavailable:
                EmptyView()
            }
        } header: {
            Text("Away From Home")
        } footer: {
            switch mac.tailnet.state {
            case .unavailable:
                // A Mac can't be a tailnet node of its own (TailscaleKit has no Mac Catalyst build).
                Text("Away from home, Lantern reaches the serving Mac through the Tailscale app, signed in to the same tailnet. Without it, Lantern works on your home network only.")
            case .connected:
                Text("Lantern is on your tailnet as its own device, so your Mac answers away from home too.")
            default:
                Text("If the Mac has Tailscale set up, pairing joins its tailnet by itself. Otherwise sign in here, or use the Tailscale app.")
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.tint)
                .frame(width: 26, height: 26)
                .background(.tint.opacity(0.15), in: .circle)
            Text(text)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func paste() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), let offer = PairOffer(url: url) else {
            pasteProblem = "There's no pairing link on the clipboard. Copy it on the Mac first."
            return
        }
        pasteProblem = nil
        pairing = .link(offer)
    }

    private func pairWithCode() {
        guard let normalized = MacPairing.normalizedCode(code) else { return }
        codeFocused = false
        pairing = .code(normalized, browser.advertised)
    }
}
