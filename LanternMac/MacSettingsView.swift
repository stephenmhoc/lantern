import SwiftUI

/// Lantern › Settings (⌘,): how answers look, the instructions new chats start with, Lantern's own
/// models, web search, and Devices: connecting iPhones and iPads to this Mac's models.
struct MacSettingsView: View {
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Personalization", systemImage: "person.text.rectangle", value: "personalization") { MacPersonalization() }
            Tab("Models", systemImage: "cpu", value: "models") { ModelsSettings() }
            Tab("Web Search", systemImage: "magnifyingglass", value: "search") { SearchSettings() }
            Tab("Devices", systemImage: "iphone.and.arrow.forward", value: "devices") { DevicesSettings() }
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(BridgeController.self) private var bridge
    @AppStorage(ReplyDetails.key) private var showDetails = true

    var body: some View {
        @Bindable var bridge = bridge
        Form {
            Section {
                Toggle("Speed and Tokens", isOn: $showDetails)
            } footer: {
                Text("The line under each answer: the model, how fast it answered and how long it waited. Off, it keeps only notes that an answer was stopped or cut off.")
            }
            Section {
                Toggle("Open at Login", isOn: $bridge.opensAtLogin)
            } footer: {
                Text("Your iPhone and iPad can use this Mac's models only while Lantern is running. Closing its windows keeps it in the menu bar.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Personalization

private struct MacPersonalization: View {
    @AppStorage(Engine.customPromptKey) private var customPrompt = ""
    @State private var text = Engine.customInstructions ?? Engine.defaultInstructions

    private var isDefault: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == Engine.defaultInstructions
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 140)
                    .onChange(of: text) { _, new in
                        customPrompt = isDefault ? "" : new.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                if !isDefault {
                    Button("Use the Default Instructions") { text = Engine.defaultInstructions }
                }
            } header: {
                Text("Instructions")
            } footer: {
                Text("Every model gets these at the start of a new chat, followed by the day it began. Chats you already have keep the instructions they started with.")
            }
            Section("A new chat starts with") {
                Text(Engine.systemPrompt())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Models

/// Lantern's own models (llama.cpp, in Application Support) and Apple Intelligence. This Mac's
/// model servers manage their own: they're under Devices.
private struct ModelsSettings: View {
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store

    var body: some View {
        Form {
            Section {
                ForEach(CatalogModel.all, id: \.id) { model in
                    ModelLine(model: model)
                }
            } header: {
                Text("Lantern's Models")
            } footer: {
                Text("They run inside Lantern, with no model server. Ollama, LM Studio and the others keep their own models; Lantern finds them on its own.")
            }
            Section {
                ForEach(CatalogModel.extras, id: \.id) { model in
                    ModelLine(model: model)
                }
            } header: {
                Text("Pictures")
            } footer: {
                Text("Lets each Gemma see images you attach. Loaded only for a chat with a picture.")
            }
            Section(Mode.apple.title) {
                LabeledContent(Mode.apple.title, value: engine.apple.status.short)
                if !engine.apple.status.isAvailable {
                    Text(engine.apple.status.explanation).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Folders.models]) }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
    }
}

private struct ModelLine: View {
    @Environment(ModelStore.self) private var store
    let model: CatalogModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            switch store.states[model.id] ?? .missing {
            case .ready:
                Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)).foregroundStyle(.secondary)
                Button("Delete", role: .destructive) { store.delete(model) }
            case .downloading(let p):
                ProgressView(value: p).frame(width: 90)
                Button("Cancel") { store.cancel(model) }
            case .failed(let reason):
                Text(reason).foregroundStyle(.red).font(.caption)
                Button("Try Again") { store.download(model) }
            case .missing, .incomplete:
                Button("Download \(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))") { store.download(model) }
            }
        }
    }
}

// MARK: - Web search

private struct SearchSettings: View {
    @AppStorage(Engine.webSearchKey) private var webSearch = false
    @State private var key = WebSearcher.storedKey ?? ""

    var body: some View {
        Form {
            Section {
                Toggle("Search the Web", isOn: $webSearch)
                if webSearch {
                    SecureField("Tavily API Key", text: $key)
                        .onChange(of: key) { _, k in WebSearcher.setKey(k) }
                    Link("Get a free key at tavily.com", destination: URL(string: "https://tavily.com")!)
                        .font(.caption)
                }
            } footer: {
                Text("Every model can look things up while it answers. This Mac sends the searches to Tavily with your own key." + (webSearch && key.isEmpty ? " Add a key to start searching." : ""))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Devices

/// The setup for other devices: whether they can reach this Mac, pairing one (its QR code),
/// the ones paired, the models they see (and which stay loaded), and Ollama's own exposure.
private struct DevicesSettings: View {
    @Environment(BridgeController.self) private var bridge
    @Environment(\.openWindow) private var openWindow
    @State private var fixingOllama = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(summary)
                    }
                }
                if case .failed = bridge.state { Button("Restart") { bridge.restart() } }
                if let status = bridge.status {
                    DisclosureGroup("Connection Details") {
                        LabeledContent("Addresses") {
                            Text(status.addresses.joined(separator: "\n")).textSelection(.enabled)
                        }
                        LabeledContent("Certificate") {
                            Text(status.fingerprint.prefix(23) + "…").font(.caption.monospaced()).textSelection(.enabled)
                                .help("Devices check this fingerprint, so nothing can pretend to be this Mac.")
                        }
                    }
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text("Your iPhone and iPad reach this Mac's models through Lantern, encrypted, at home or over Tailscale. Each one pairs once.")
            }

            Section {
                HStack {
                    Text(devices.isEmpty ? "No devices yet" : devices.count == 1 ? "1 device" : "\(devices.count) devices")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Pair a Device…") { openWindow(id: PairingView.windowID) }
                        .buttonStyle(.borderedProminent)
                        .disabled(bridge.state != .running)
                }
                ForEach(devices) { device in
                    HStack {
                        Image(systemName: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.lastSeen.flatMap { $0 > .distantPast ? $0 : nil }
                                .map { "Last used \($0.formatted(.relative(presentation: .named)))" }
                                ?? "Paired \(device.paired.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unpair") { Task { await bridge.remove(device) } }
                    }
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("On the iPhone or iPad: Lantern › Settings › On Your Computers › Add a Computer, then scan the code with the Camera.")
            }

            if bridge.ollamaIsExposed {
                Section {
                    Label("Ollama is open to your network", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Anything on your Wi-Fi can use it, unencrypted. Your devices only need Lantern's encrypted connection.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(fixingOllama ? "Restarting Ollama…" : "Keep Ollama on This Mac") {
                        fixingOllama = true
                        Task { await bridge.makeOllamaPrivate(); fixingOllama = false }
                    }
                    .disabled(fixingOllama)
                }
            }

            if let status = bridge.status {
                Section {
                    if status.models.isEmpty { Text("None yet. Open Ollama or LM Studio.").foregroundStyle(.secondary) }
                    ForEach(status.models) { model in
                        let kept = status.keepLoaded.contains(model.id)
                        HStack {
                            VStack(alignment: .leading) {
                                Text(MacLink.displayName(model.id))
                                Text("\(model.lantern.backend_name) · \(model.id)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.lantern.backend == "ollama" {
                                Toggle("Keep Loaded", isOn: Binding(get: { kept }, set: { k in Task { await bridge.keepLoaded(model, k) } }))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                } header: {
                    Text("Models on This Mac")
                } footer: {
                    Text("From \(ListFormatter.localizedString(byJoining: status.backends.map(\.name)).nilIfEmpty ?? "no model servers yet"). Kept loaded, a model answers the first question without loading.")
                }
            }
        }
        .formStyle(.grouped)
        .task { await bridge.refresh() }
    }

    /// Paired devices, without this app's own pairing with its bridge.
    private var devices: [BridgeController.Device] {
        (bridge.status?.devices ?? []).filter { $0.name != ThisMac.deviceName }
    }

    private var statusColor: Color {
        switch bridge.state {
        case .starting: .yellow
        case .failed: .red
        case .running: bridge.status?.backends.isEmpty == false ? .green : .yellow
        }
    }

    private var summary: String {
        switch bridge.state {
        case .starting: "Starting…"
        case .failed(let reason): reason
        case .running: bridge.status.map { $0.backends.isEmpty ? "Running, no model servers yet" : "Serving your devices" } ?? "Starting…"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
