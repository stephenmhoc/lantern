import SwiftUI

/// Settings › Mac: the paired Mac, whose model a chat can use through Lantern's bridge. What it
/// is, whether it answers and how Lantern reaches it, and the way to unpair. Without one it's the
/// pairing page (`AddComputerView`). It checks the Mac while open, and only then: nothing here
/// runs at launch.
struct ComputersView: View {
    @Environment(MacLink.self) private var mac
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MacLink.lanKey) private var lanHost = MacLink.defaultLAN
    @AppStorage(MacLink.tailnetKey) private var tailnetHost = MacLink.defaultTailnet
    @AppStorage(MacLink.computerNameKey) private var storedName = ""
    @AppStorage(MacLink.modelKey) private var modelName = ""
    @State private var confirmingRemove = false

    /// A Mac is set up once this device is paired with its bridge.
    private var configured: Bool {
        MacPairing.isPaired && (MacLink.normalized(lanHost) != nil || MacLink.normalized(tailnetHost) != nil)
    }
    private var name: String { MacLink.computerName(stored: storedName, lan: lanHost, tailnet: tailnetHost) }

    var body: some View {
        Group {
            if configured { page } else { AddComputerView() }
        }
        .navigationTitle("Mac")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var page: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 88, height: 88)
                        .background(.tint.opacity(colorScheme == .dark ? 0.18 : 0.12), in: .circle)
                        .accessibilityHidden(true)
                    Text(name).font(.title.bold()).multilineTextAlignment(.center)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(Self.status(of: mac.route))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
            }

            Section {
                LabeledContent("Model", value: modelName.isEmpty ? "None Yet" : MacLink.displayName(modelName))
            } footer: {
                Text(modelName.isEmpty
                     ? "Lantern will show \(name)'s model once it answers."
                     : Device.isMac ? "Chats with it are encrypted from this Mac to \(name)."
                     : "Pick it for a chat where you pick the model. Chats with it are encrypted from this \(Device.name) to \(name).")
            }

            Section {
                LabeledContent("At Home", value: MacLink.normalized(lanHost) == nil ? "Not Set Up" : "Your Network")
                TailscaleRows(tailnet: mac.tailnet, route: mac.route)
            } header: {
                Text("How Lantern Reaches It")
            } footer: {
                Text("At home Lantern uses your own network, which works with the internet down. Away from home it uses your tailnet.")
            }

            Section {
                Button("Unpair \(name)", role: .destructive) { confirmingRemove = true }
            } footer: {
                Text(Device.isMac ? "To use another Mac instead, unpair this one, then paste the other's pairing link."
                     : "To use another Mac instead, scan its pairing code with the camera.")
            }
        }
        .confirmationDialog("Unpair \(name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { mac.removeComputer() }
        } message: {
            Text(Device.isMac ? "Lantern forgets how to reach it. Your chats stay, for when this Mac is paired again."
                 : "Lantern forgets how to reach it. Your chats stay, and carry on with this \(Device.name)'s model.")
        }
        // Checks while the page is open, and again when its addresses change.
        .task(id: "\(lanHost)\n\(tailnetHost)") { await mac.resolve() }
    }

    /// "Connected at home", "Connected over your tailnet", "Looking for it…", "Not reachable right now".
    static func status(of route: MacLink.Route) -> String {
        switch route {
        case .unknown, .checking: "Looking for it…"
        case .unreachable: "Not reachable right now"
        case .lan: "Connected at home"
        case .tailnet(_, let viaApp): viaApp ? "Connected through the Tailscale app" : "Connected over your tailnet"
        }
    }

    private var statusColor: Color {
        switch mac.route {
        case .lan, .tailnet: .green
        case .unreachable: .orange
        default: .secondary
        }
    }
}

/// Lantern's own tailnet node, or the Tailscale app's VPN when that's the way it answered.
struct TailscaleRows: View {
    let tailnet: Tailnet
    let route: MacLink.Route
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if case .tailnet(_, viaApp: true) = route, tailnet.state != .connected {
                LabeledContent("Away From Home", value: "The Tailscale App")
            } else {
                switch tailnet.state {
                case .unavailable:
                    LabeledContent("Away From Home", value: "The Tailscale App")
                case .signedOut, .failed:
                    Button("Sign In with Tailscale") { Task { await tailnet.signIn() } }
                        .frame(minHeight: 44).tint(.primary)
                    if case .failed(let message) = tailnet.state {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    }
                case .starting:
                    LabeledContent("Away From Home") { HStack { Text("Connecting…"); ProgressView() } }
                case .needsLogin(let url):
                    Button("Open Tailscale Sign-In") { openURL(url) }.frame(minHeight: 44).tint(.primary)
                case .connected:
                    LabeledContent("Away From Home", value: tailnet.account ?? "Your Tailnet")
                    Button("Sign Out of Tailscale", role: .destructive) { Task { await tailnet.signOut() } }
                        .frame(minHeight: 44)
                }
            }
        }
        .onChange(of: tailnet.state) { _, state in
            if case .needsLogin(let url) = state { openURL(url) }
        }
    }
}
