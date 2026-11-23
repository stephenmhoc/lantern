import LlamaKit
import SwiftUI

struct SettingsView: View {
    @Environment(MacLink.self) private var mac
    @Environment(Engine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(MacLink.lanKey) private var lanHost = MacLink.defaultLAN
    @AppStorage(MacLink.tailnetKey) private var tailnetHost = ""
    @AppStorage(MacLink.modelKey) private var modelName = ""
    /// The hosts last checked (or as Settings opened with), so only edits trigger a check.
    @State private var openedWith: String?

    private var hosts: String { "\(lanHost)\n\(tailnetHost)" }

    var body: some View {
        Form {
            Section {
                LabeledContent("Home network") {
                    TextField(MacLink.defaultLAN, text: $lanHost)
                        .multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                LabeledContent("Tailnet") {
                    TextField("mac-studio.example.ts.net", text: $tailnetHost)
                        .multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                LabeledContent("Connected by", value: mac.route.label)
                if !mac.models.isEmpty {
                    Picker("Model", selection: $modelName) {
                        ForEach(mac.models, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button("Check connection") { Task { await mac.resolve() } }
            } header: {
                Text("Mac")
            } footer: {
                Text("""
                    Ollama has to listen on your network: on the Mac, run `launchctl setenv OLLAMA_HOST 0.0.0.0` \
                    and restart Ollama. Port 11434 is assumed unless you add one.
                    """)
            }

            TailnetSection(tailnet: mac.tailnet, host: $tailnetHost, openURL: openURL)

            Section("This device") {
                LabeledContent("Memory", value: MemoryStats.gb(MemoryStats.deviceBytes))
                LabeledContent("Lantern is using", value: MemoryStats.gb(MemoryStats.footprintBytes))
                if let free = MemoryStats.availableBytes {
                    LabeledContent("Free for models", value: MemoryStats.gb(free))
                }
                LabeledContent("Loaded model", value: engine.loadedModel?.name ?? "None")
                if engine.loadedModel != nil {
                    Button("Unload model") { engine.unload() }.disabled(engine.isBusy)
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        // Checks the Mac once typing pauses, not on every keystroke: a new keystroke cancels the
        // wait. Opening Settings doesn't check by itself.
        .task(id: hosts) {
            guard let opened = openedWith else { openedWith = hosts; return }
            guard hosts != opened else { return }
            openedWith = hosts
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await mac.resolve()
        }
    }
}

/// Signs Lantern into your tailnet as its own device, so the Mac is reachable away from home without
/// the Tailscale app. Pick the Mac from the tailnet's devices once connected.
private struct TailnetSection: View {
    let tailnet: Tailnet
    @Binding var host: String
    let openURL: OpenURLAction

    var body: some View {
        if tailnet.state != .unavailable {
            Section {
                LabeledContent("Status", value: tailnet.state.label)
                switch tailnet.state {
                case .signedOut, .failed:
                    Button("Sign in to Tailscale") { Task { await tailnet.signIn() } }
                case .needsLogin(let url):
                    Button("Open sign-in page") { openURL(url) }
                case .connected:
                    if !tailnet.peers.isEmpty {
                        Picker("Mac", selection: $host) {
                            Text("Choose…").tag("")
                            ForEach(tailnet.peers, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button("Sign out", role: .destructive) { Task { await tailnet.signOut() } }
                default:
                    EmptyView()
                }
            } header: {
                Text("Tailscale")
            } footer: {
                Text("Lantern joins your tailnet as its own device. Signing in needs the internet; the home network works without it.")
            }
            .onChange(of: tailnet.state) { _, state in
                if case .needsLogin(let url) = state { openURL(url) }
            }
            .task(id: tailnet.state) { if tailnet.state == .connected { await tailnet.refreshPeers() } }
        }
    }
}
