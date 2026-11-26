import SwiftUI
import UIKit

/// Add a Computer: pairing with Lantern on a Mac, whose bridge serves its local models (Ollama,
/// LM Studio…) to paired devices, encrypted. Pairing takes the one-time code its "Pair a Device"
/// shows, as a QR code for the camera or a link sent by AirDrop or pasted here; computers running
/// the bridge on this network are listed so it's clear which to pair with. It's the sheet from Your
/// Computers and, with no computer yet, that page itself (`inline`).
struct AddComputerView: View {
    enum Presentation { case sheet, inline }
    let presentation: Presentation
    /// Paired (or the sheet was cancelled).
    let done: () -> Void

    @Environment(MacLink.self) private var mac
    @Environment(\.openURL) private var openURL
    @State private var browser = BridgeBrowser()
    @State private var pairing: LanternLink.PairOffer?
    @State private var pasteProblem: String?

    var body: some View {
        List {
            if presentation == .inline {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.black)
                            .frame(width: 56, height: 56)
                            .background(Color.accentColor, in: .rect(cornerRadius: 14))
                            .accessibilityHidden(true)
                        Text("Add a Computer").font(.title2.bold())
                        Text("Use the models on your Mac (Ollama, LM Studio and others), over your home network or your tailnet, encrypted all the way.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            Section {
                step(1, "Open Lantern on your Mac. It lives in the menu bar.")
                step(2, "Choose \u{201C}Pair a Device…\u{201D}")
                step(3, "Point this \(UIDevice.current.localizedModel)'s camera at the code and open the link in Lantern.")
                Button("Paste a Pairing Link", systemImage: "doc.on.clipboard", action: paste)
                    .frame(minHeight: 44)
                    .tint(.primary)
            } header: {
                Text("Pair With Your Mac")
            } footer: {
                Text(pasteProblem ?? "Or send the link from the Mac with \u{201C}Send to a Device…\u{201D}, and paste it here.")
            }

            Section {
                ForEach(browser.found) { found in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(found.name)
                            Text("Ready to pair: scan its code").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
                if browser.found.isEmpty {
                    if let problem = browser.problem {
                        Text(problem).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking on this network…").foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                }
            } header: {
                Text("On This Network")
            }

            tailnetSection
        }
        .navigationTitle(presentation == .sheet ? "Add a Computer" : "Your Computers")
        .navigationBarTitleDisplayMode(presentation == .sheet ? .inline : .automatic)
        .toolbar {
            if presentation == .sheet {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .onChange(of: mac.tailnet.state) { _, state in
            if case .needsLogin(let url) = state { openURL(url) }
        }
        .sheet(item: $pairing, onDismiss: { if MacPairing.isPaired, MacLink.isConfigured { done() } }) {
            PairingSheet(offer: $0)
        }
    }

    /// Lantern's own tailnet node, for reaching the Mac away from home without the Tailscale app.
    @ViewBuilder private var tailnetSection: some View {
        Section {
            switch mac.tailnet.state {
            case .connected:
                Label("Signed in", systemImage: "checkmark.circle.fill").frame(minHeight: 44)
            case .signedOut, .failed:
                Button("Sign In with Tailscale") { Task { await mac.tailnet.signIn() } }
                    .frame(minHeight: 44).tint(.primary)
            case .needsLogin(let url):
                Button("Open Tailscale Sign-In") { openURL(url) }.frame(minHeight: 44).tint(.primary)
            case .starting:
                HStack(spacing: 10) { ProgressView(); Text("Connecting to your tailnet…").foregroundStyle(.secondary) }
                    .frame(minHeight: 44)
            case .unavailable:
                EmptyView()
            }
        } header: {
            if mac.tailnet.state != .unavailable { Text("Away From Home") }
        } footer: {
            if mac.tailnet.state != .unavailable {
                Text(mac.tailnet.state == .connected
                     ? "Lantern is on your tailnet as its own device, so your Mac answers away from home too."
                     : "With Tailscale, your Mac answers away from home too. Sign in here, or use the Tailscale app.")
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 24, height: 24)
                .background(.quaternary, in: .circle)
            Text(text)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func paste() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), case .pair(let offer)? = LanternLink(url: url) else {
            pasteProblem = "There's no pairing link to paste. On the Mac, choose \u{201C}Send to a Device…\u{201D} or copy the link first."
            return
        }
        pasteProblem = nil
        pairing = offer
    }
}
