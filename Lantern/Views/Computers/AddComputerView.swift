import SwiftUI

/// Add a Computer: one live list of the computers running Ollama that Lantern can find (on this
/// network by Bonjour, on your tailnet through Lantern's node, and the saved or default names),
/// plus an address typed by hand. Choosing one saves both its routes, picks the model new chats
/// use, tests it, and says "Ready". It's the sheet from Your Computers and, with no computer yet,
/// that page itself (`inline`). Finding runs only while it's on screen.
struct AddComputerView: View {
    enum Presentation { case sheet, inline }
    let presentation: Presentation
    /// Setup finished (or the sheet was cancelled).
    let done: () -> Void

    @Environment(MacLink.self) private var mac
    @Environment(\.openURL) private var openURL
    @State private var finder: ComputerFinder?
    @State private var phase: Phase = .choosing

    enum Phase {
        case choosing
        case connecting(String)
        case ready(String, models: Int, MacLink.ConnectionTest)
        case failed(String, MacLink.ConnectionTest)
    }

    var body: some View {
        List {
            switch phase {
            case .choosing: choosing
            case .connecting(let name): connecting(name)
            case .ready(let name, let models, let test): ready(name, models: models, test: test)
            case .failed(let name, let test): failed(name, test)
            }
        }
        .navigationTitle(presentation == .sheet ? "Add a Computer" : "Your Computers")
        .navigationBarTitleDisplayMode(presentation == .sheet ? .inline : .automatic)
        .toolbar {
            if presentation == .sheet, case .choosing = phase {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
            }
        }
        .onAppear(perform: startFinding)
        #if DEBUG
        // `-ui addcomputer:pick`: chooses the first computer found, for checking the setup.
        .task {
            guard DebugLaunch.ui == "addcomputer:pick" else { return }
            try? await Task.sleep(for: .seconds(5))
            if let first = finder?.found.first { choose(first) }
        }
        #endif
        .onDisappear { finder?.stop() }
        .task(id: mac.tailnet.state) {
            if mac.tailnet.state == .connected, case .choosing = phase { finder?.probeTailnet() }
        }
        .onChange(of: mac.tailnet.state) { _, state in
            if case .needsLogin(let url) = state { openURL(url) }
        }
    }

    private func startFinding() {
        if finder == nil { finder = ComputerFinder(mac: mac) }
        if case .choosing = phase { finder?.start() }
    }

    // MARK: Choosing

    @ViewBuilder
    private var choosing: some View {
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
                    Text("Use the models in Ollama on your Mac or PC, over your home network or your tailnet.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }

        let finder = finder
        Section {
            ForEach(finder?.onNetwork ?? []) { computerRow($0) }
            if finder?.onNetwork.isEmpty ?? true {
                if let problem = finder?.browseProblem {
                    Text(problem).foregroundStyle(.secondary)
                } else {
                    searchingRow("Looking on this network…")
                }
            }
        } header: {
            Text("On This Network")
        } footer: {
            Text("""
                Ollama has to listen on the network: in its settings, turn on \u{201C}Expose Ollama to the \
                network\u{201D}. A Mac set up with Lantern's script shows up here by itself.
                """)
        }

        Section {
            switch mac.tailnet.state {
            case .connected:
                ForEach(finder?.onTailnetOnly ?? []) { computerRow($0) }
                if finder?.probingTailnet == true {
                    searchingRow("Asking each device on your tailnet…")
                } else if finder?.onTailnetOnly.isEmpty ?? true {
                    Text(finder?.found.contains { $0.tailnetHost != nil } == true
                         ? "Computers on both are listed above." : "No device on your tailnet answered as Ollama.")
                        .foregroundStyle(.secondary)
                }
            case .signedOut, .failed:
                ForEach(finder?.onTailnetOnly ?? []) { computerRow($0) }
                Button("Sign In with Tailscale") { Task { await mac.tailnet.signIn() } }
                    .frame(minHeight: 44).tint(.primary)
            case .needsLogin(let url):
                Button("Open Tailscale Sign-In") { openURL(url) }.frame(minHeight: 44).tint(.primary)
            case .starting:
                searchingRow("Connecting to your tailnet…")
            case .unavailable:
                ForEach(finder?.onTailnetOnly ?? []) { computerRow($0) }
            }
        } header: {
            Text("On Your Tailnet")
        } footer: {
            Text(mac.tailnet.state == .connected
                 ? "Lantern is on your tailnet as its own device."
                 : "Sign in to reach your computer away from home without the Tailscale app. Signing in needs the internet.")
        }

        Section {
            NavigationLink {
                ManualComputerView { lan, tailnet in choose(manualLAN: lan, tailnet: tailnet) }
            } label: {
                Text("Enter an Address").frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private func computerRow(_ computer: FoundComputer) -> some View {
        Button { choose(computer) } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(computer.name)
                    Text(computer.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Sets it up")
    }

    private func searchingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    // MARK: Setting up

    private func connecting(_ name: String) -> some View {
        Section {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Connecting to \(name)…").font(.headline)
                Text("Checking the home network and your tailnet, then loading a model.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func ready(_ name: String, models: Int, test: MacLink.ConnectionTest) -> some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(.green).accessibilityHidden(true)
                Text("Ready: \(models == 1 ? "1 model" : "\(models) models")").font(.title2.bold())
                Text("\(name) · \(test.route.label)").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .accessibilityElement(children: .combine)
        }
        Section("Test") {
            LabeledContent("Found", value: ComputersView.seconds(test.timings.findSeconds))
            LabeledContent("Connected", value: test.timings.connectSeconds.map(ComputersView.seconds) ?? "Already open")
            LabeledContent("Loaded \(MacLink.displayName(mac.modelName))", value: ComputersView.seconds(test.timings.loadSeconds))
        }
        Section {
            Button(action: done) {
                Text("Done").fontWeight(.semibold).modifier(ProminentLabel())
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private func failed(_ name: String, _ test: MacLink.ConnectionTest) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't reach \(name)").font(.headline)
                    Text(test.failure ?? "No answer.").foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .padding(.vertical, 6)
        } footer: {
            Text("Its addresses are saved, so Lantern tries again when you ask it something.")
        }
        Section {
            Button("Try Again") { Task { await setUp(name: name, previous: mac.modelName) } }.frame(minHeight: 44)
            Button("Choose Another Computer") {
                phase = .choosing
                finder?.start()
            }
            .frame(minHeight: 44)
            Button("Keep It Anyway", action: done).frame(minHeight: 44)
        }
        .tint(.primary)  // amber text on white is 2.3:1
    }

    // MARK: Choosing one

    private func choose(_ computer: FoundComputer) {
        var lan = computer.lanHost ?? ""
        var tail = computer.tailnetHost ?? ""
        // The same computer's other route, by name: its Bonjour host matched to a tailnet peer
        // ("stephens-mac-studio"), or the address saved before.
        if tail.isEmpty, let peer = mac.tailnet.peers.first(where: { MacLink.slug($0) == computer.id }) { tail = peer }
        if tail.isEmpty, MacLink.slug(MacLink.tailnetHost) == computer.id { tail = MacLink.tailnetHost }
        if lan.isEmpty, MacLink.slug(MacLink.lanHost) == computer.id { lan = MacLink.lanHost }
        let previous = mac.modelName
        mac.configure(name: computer.name, lan: lan, tailnet: tail)
        Task { await setUp(name: computer.name, previous: previous) }
    }

    private func choose(manualLAN host: String, tailnet: String) {
        // A tailnet name typed as the address goes where it belongs.
        let lan = MacLink.isTailnetHost(host) ? "" : host
        let tail = tailnet.isEmpty && MacLink.isTailnetHost(host) ? host : tailnet
        let name = MacLink.computerName(stored: nil, lan: lan, tailnet: tail)
        let previous = mac.modelName
        mac.configure(name: nil, lan: lan, tailnet: tail)
        Task { await setUp(name: name, previous: previous) }
    }

    /// Finds it, keeps the model new chats use if it has it (else its first), and tests it.
    private func setUp(name: String, previous: String) async {
        finder?.stop()
        phase = .connecting(name)
        await mac.resolve()
        if !mac.models.isEmpty {
            let pick = mac.models.contains(previous) ? previous : mac.models[0]
            UserDefaults.standard.set(pick, forKey: MacLink.modelKey)
        }
        let test = await mac.testConnection(model: mac.modelName)
        phase = test.failure == nil ? .ready(name, models: mac.models.count, test) : .failed(name, test)
    }
}

/// An address typed by hand: a host or IP, and optionally its tailnet name.
struct ManualComputerView: View {
    let connect: (_ host: String, _ tailnet: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var tailnet = ""

    var body: some View {
        Form {
            Section {
                TextField("Host or IP address", text: $host)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                    .submitLabel(.next)
            } footer: {
                Text("For example Mac-Studio.local or 192.168.1.20. Port 11434 unless you add one.")
            }
            Section {
                TextField("Tailnet name (optional)", text: $tailnet)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(submit)
            } footer: {
                Text("Its MagicDNS name, such as mac-studio.tail1234.ts.net, to reach it away from home. It's tried through Lantern's own tailnet connection and the Tailscale app.")
            }
            Section {
                Button(action: submit) {
                    Text("Connect").fontWeight(.semibold).modifier(ProminentLabel())
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(trimmed(host).isEmpty && trimmed(tailnet).isEmpty)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("Enter an Address")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    private func submit() {
        guard !(trimmed(host).isEmpty && trimmed(tailnet).isEmpty) else { return }
        connect(trimmed(host), trimmed(tailnet))
        dismiss()
    }
}
