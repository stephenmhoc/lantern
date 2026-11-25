import SwiftUI

/// Settings › On Your Computers: the computer Ollama runs on (a Mac Studio, reached over the home
/// network or the tailnet), its models and how Lantern reaches it. Without one it's the Add a
/// Computer list. It checks the computer while open, and only then: nothing here runs at launch.
struct ComputersView: View {
    @Environment(MacLink.self) private var mac
    @AppStorage(MacLink.lanKey) private var lanHost = MacLink.defaultLAN
    @AppStorage(MacLink.tailnetKey) private var tailnetHost = MacLink.defaultTailnet
    @AppStorage(MacLink.computerNameKey) private var storedName = ""
    @AppStorage(MacLink.modelKey) private var modelName = ""
    @State private var version: String?
    @State private var loaded: Set<String> = []
    @State private var capabilities: [String: Set<String>] = [:]
    @State private var test: MacLink.ConnectionTest?
    @State private var testing = false
    @State private var adding = false
    @State private var confirmingRemove = false
    /// The inline Add a Computer list stays up through its setup, after the addresses are saved.
    @State private var addingInline = false

    private var configured: Bool { MacLink.normalized(lanHost) != nil || MacLink.normalized(tailnetHost) != nil }
    private var name: String { MacLink.computerName(stored: storedName, lan: lanHost, tailnet: tailnetHost) }

    var body: some View {
        Group {
            if addingInline || !configured {
                AddComputerView(presentation: .inline) { addingInline = false }
            } else {
                page
            }
        }
        .navigationTitle("Your Computers")
        .onChange(of: configured, initial: true) { _, configured in
            if !configured { addingInline = true }
        }
    }

    private var page: some View {
        ScrollViewReader { proxy in
            list
            #if DEBUG
                // `-ui computers:bottom`: runs the test and scrolls down to it, for screenshots.
                .task {
                    guard DebugLaunch.ui == "computers:bottom" else { return }
                    try? await Task.sleep(for: .seconds(1))
                    await runTest()
                    proxy.scrollTo("connection", anchor: .top)
                }
            #endif
        }
    }

    private var list: some View {
        List {
            header
            modelsSection
            connectionSection.id("connection")
            testSection
            Section {
                Button("Remove Computer", role: .destructive) { confirmingRemove = true }
                    .frame(minHeight: 44)
            } footer: {
                Text("Lantern uses one computer at a time. Adding another replaces \(name).")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add a Computer", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { AddComputerView(presentation: .sheet) { adding = false } }
                .environment(mac)
        }
        .confirmationDialog("Remove \(name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove Computer", role: .destructive) {
                mac.removeComputer()
                test = nil
            }
        } message: {
            Text("Lantern forgets how to reach it. Chats with its models stay, and you can add it again.")
        }
        // Checks while the page is open: when it opens, when the addresses change, and the loaded
        // models every 15 seconds. Leaving the page cancels it.
        .task(id: "\(lanHost)\n\(tailnetHost)") {
            await mac.resolve()
            await refreshDetails()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, mac.route.host != nil else { continue }
                if let now = await mac.loadedModels() { loaded = now }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.black)
                    .frame(width: 72, height: 72)
                    .background(Color.accentColor, in: .rect(cornerRadius: 18))
                    .accessibilityHidden(true)
                Text(name).font(.title2.bold()).multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText)
                }
                .font(.subheadline)
                if let version {
                    Text("Ollama \(version)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private var statusText: String { Self.status(of: mac.route) }

    /// "Connected · Home network", "Connected · Tailnet", "Checking…", "Not reachable".
    static func status(of route: MacLink.Route) -> String {
        switch route {
        case .unknown, .checking: "Checking…"
        case .unreachable: "Not reachable"
        case .lan: "Connected · Home network"
        case .tailnet(_, let viaApp): viaApp ? "Connected · Tailnet, through the Tailscale app" : "Connected · Tailnet"
        }
    }

    private var statusColor: Color {
        switch mac.route {
        case .lan, .tailnet: .green
        case .unreachable: .orange
        default: .secondary
        }
    }

    // MARK: Models

    private var modelsSection: some View {
        Section {
            if mac.models.isEmpty {
                Text(mac.route == .unreachable ? "Lantern will list the models once it reaches \(name)." : "No models yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(mac.models, id: \.self) { model in
                Button { modelName = model } label: { modelRow(model) }
                    .tint(.primary)
                    .accessibilityAddTraits(model == modelName ? .isSelected : [])
            }
        } header: {
            Text("New Chats Use")
        } footer: {
            Text("A chat keeps the model it first answered with. To add a model, pull it in Ollama on \(name).")
        }
    }

    private func modelRow(_ model: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(MacLink.displayName(model))
                let detail = details(of: model)
                if !detail.isEmpty {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if loaded.contains(model) {
                Text("Loaded")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.green.opacity(0.2), in: .capsule)
            }
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .opacity(model == modelName ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// "20.2 GB · Thinking · Vision".
    private func details(of model: String) -> String {
        var parts: [String] = []
        if let bytes = mac.modelSizes[model], bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        let can = capabilities[model] ?? []
        if can.contains("thinking") || MacLink.alwaysThinks(model) { parts.append("Thinking") }
        if can.contains("vision") { parts.append("Vision") }
        return parts.joined(separator: " · ")
    }

    // MARK: How it connects

    private var connectionSection: some View {
        Section {
            NavigationLink { ComputerDetailsView() } label: {
                addressRow("Home network", lanHost)
            }
            NavigationLink { ComputerDetailsView() } label: {
                addressRow("Tailnet", tailnetHost)
            }
            TailscaleRows(tailnet: mac.tailnet, route: mac.route)
        } header: {
            Text("How It Connects")
        } footer: {
            Text("""
                Lantern tries the home network first: it works with the internet down, if the router \
                and \(name) have power. Away from home it uses your tailnet.
                """)
        }
    }

    private func addressRow(_ title: String, _ host: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(host.isEmpty ? "Not set" : host)
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Test

    private var testSection: some View {
        Section {
            Button {
                Task { await runTest() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if testing { ProgressView() }
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .disabled(testing)
            .tint(.primary)  // amber text on white is 2.3:1
            if let test, !testing {
                if let failure = test.failure {
                    Label {
                        Text(failure)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                LabeledContent("Found", value: "\(Self.seconds(test.timings.findSeconds)) · \(test.route.label)")
                if test.failure == nil {
                    LabeledContent("Connected", value: test.timings.connectSeconds.map(Self.seconds) ?? "Already open")
                    LabeledContent("Loaded \(MacLink.displayName(modelName))", value: Self.seconds(test.timings.loadSeconds))
                }
            }
        } footer: {
            Text("Finds \(name) the way a question would, then loads the model new chats use.")
        }
    }

    static func seconds(_ s: Double) -> String {
        s < 10 ? String(format: "%.2f s", s) : String(format: "%.0f s", s)
    }

    private func runTest() async {
        testing = true
        test = await mac.testConnection(model: modelName)
        testing = false
        await refreshDetails()
    }

    /// Version, loaded models and capabilities, all at once.
    private func refreshDetails() async {
        guard mac.route.host != nil else { return }
        async let v = mac.ollamaVersion()
        async let ps = mac.loadedModels()
        let models = mac.models
        var found: [String: Set<String>] = [:]
        await withTaskGroup(of: (String, Set<String>?).self) { group in
            for model in models { group.addTask { (model, await mac.capabilities(of: model)) } }
            for await (model, set) in group { if let set { found[model] = set } }
        }
        capabilities = found
        version = await v
        loaded = await ps ?? loaded
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
                LabeledContent("Tailscale", value: "Using the Tailscale app")
            } else {
                switch tailnet.state {
                case .unavailable:
                    LabeledContent("Tailscale", value: "Through the Tailscale app")
                case .signedOut, .failed:
                    Button("Sign In with Tailscale") { Task { await tailnet.signIn() } }
                        .frame(minHeight: 44).tint(.primary)
                    if case .failed(let message) = tailnet.state {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    }
                case .starting:
                    LabeledContent("Tailscale") { HStack { Text("Connecting…"); ProgressView() } }
                case .needsLogin(let url):
                    Button("Open Tailscale Sign-In") { openURL(url) }.frame(minHeight: 44).tint(.primary)
                case .connected:
                    LabeledContent("Tailscale", value: tailnet.account.map { "Connected as \($0)" } ?? "Connected")
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

/// The computer's name and addresses, edited together and saved with Save.
struct ComputerDetailsView: View {
    @Environment(MacLink.self) private var mac
    @Environment(\.dismiss) private var dismiss
    @State private var name = UserDefaults.standard.string(forKey: MacLink.computerNameKey) ?? ""
    @State private var lan = MacLink.lanHost
    @State private var tailnet = MacLink.tailnetHost

    var body: some View {
        Form {
            Section {
                TextField(MacLink.derivedName(fromHost: lan) ?? MacLink.derivedName(fromHost: tailnet) ?? "Computer", text: $name)
            } header: {
                Text("Name")
            } footer: {
                Text("How the model picker names it: \u{201C}On Your \(MacLink.computerName(stored: name, lan: lan, tailnet: tailnet))\u{201D}.")
            }
            Section {
                TextField(MacLink.defaultLAN, text: $lan)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
            } header: {
                Text("Home Network")
            } footer: {
                Text("Its .local name or IP address. Port 11434 unless you add one.")
            }
            Section {
                TextField("name.tail1234.ts.net", text: $tailnet)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                if mac.tailnet.state == .connected, !mac.tailnet.peers.isEmpty {
                    Picker("Choose from Your Tailnet", selection: $tailnet) {
                        if !mac.tailnet.peers.contains(tailnet) { Text(tailnet.isEmpty ? "None" : tailnet).tag(tailnet) }
                        ForEach(mac.tailnet.peers, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                }
            } header: {
                Text("Tailnet")
            } footer: {
                Text("Its MagicDNS name, for reaching it away from home.")
            }
        }
        .navigationTitle("Addresses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    mac.configure(name: name, lan: lan, tailnet: tailnet)
                    dismiss()
                }
                .disabled(MacLink.normalized(lan) == nil && MacLink.normalized(tailnet) == nil)
            }
        }
        .task { if mac.tailnet.state == .connected { await mac.tailnet.refreshPeers() } }
    }
}
