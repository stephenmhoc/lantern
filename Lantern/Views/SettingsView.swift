import LlamaKit
import SwiftUI

/// Pages pushed inside the Settings sheet.
enum SettingsPage: Hashable {
    case readiness
    case personalization
}

struct SettingsView: View {
    @Environment(MacLink.self) private var mac
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(ReplyDetails.key) private var showMetrics = true
    @AppStorage(Engine.webSearchKey) private var webSearch = false
    @AppStorage(Engine.customPromptKey) private var customPrompt = ""
    /// The Tavily key as typed; saved to the Keychain as it changes.
    @State private var searchKey = WebSearcher.storedKey ?? ""

    var body: some View {
        Form {
            Section("Models") {
                NavigationLink(value: SettingsPage.readiness) {
                    LabeledContent {
                        Text("\(CatalogModel.all.filter { Readiness.state($0, store: store) == .ready }.count) downloaded")
                    } label: {
                        Label("On This \(UIDevice.current.model)", systemImage: Mode.fast.symbol)
                    }
                }
                NavigationLink { ComputersView() } label: {
                    LabeledContent {
                        Text(MacLink.isConfigured ? mac.computerName : "Not set up")
                    } label: {
                        Label("On Your Computers", systemImage: "desktopcomputer")
                    }
                }
            }

            Section {
                Toggle("Speed and Tokens", isOn: $showMetrics)
            } header: {
                Text("Chats")
            } footer: {
                Text("Under each answer: the model, tokens per second and how long it took to start.")
            }

            Section {
                Toggle("Search the Web", isOn: $webSearch)
                if webSearch {
                    SecureField("Tavily API Key", text: $searchKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { WebSearcher.setKey(searchKey) }
                        .onChange(of: searchKey) { _, key in WebSearcher.setKey(key) }
                }
            } footer: {
                Text(searchFooter)
            }

            Section {
                NavigationLink(value: SettingsPage.personalization) {
                    LabeledContent {
                        Text(customPrompt.isEmpty || Engine.customInstructions == nil ? "Default" : "Custom")
                    } label: {
                        Label("Instructions", systemImage: "text.quote")
                    }
                }
            } header: {
                Text("Personalization")
            } footer: {
                Text("What every model is told at the start of a new chat.")
            }

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
    }

    /// What the switch does, and what's still missing.
    private var searchFooter: String {
        let what = "Every model, here and on your computer, can look things up while they answer. This \(UIDevice.current.model) sends their searches to Tavily, with your own API key from tavily.com."
        return webSearch && searchKey.isEmpty ? what + " Add a key to start searching." : what
    }
}
