import SwiftUI

/// Pages pushed inside the Settings sheet.
enum SettingsPage: Hashable {
    case model
    case mac
    case personalization
    /// The Mac that serves: a code for a device to pair with (`PairDeviceView`).
    case pairDevice
}

/// Settings with its pages: a sheet on iPhone and iPad, a window of its own on the Mac.
struct SettingsStack: View {
    @Binding var path: [SettingsPage]

    var body: some View {
        NavigationStack(path: $path) {
            SettingsView()
                .navigationDestination(for: SettingsPage.self) { page in
                    switch page {
                    case .model: ModelSetupView(style: .page)
                    case .mac: ComputersView()
                    case .personalization: PersonalizationView()
                    case .pairDevice:
                        #if targetEnvironment(macCatalyst)
                        PairDeviceView()
                        #else
                        EmptyView()
                        #endif
                    }
                }
        }
    }
}

/// Settings: the two models (this device's, the Mac's; on a Mac, what it does), the web search
/// key, the instructions, and which build this is.
struct SettingsView: View {
    @Environment(MacLink.self) private var mac
    @Environment(ModelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Engine.customPromptKey) private var customPrompt = ""
    /// The Tavily key as typed; saved to the Keychain as it changes.
    @State private var searchKey = WebSearcher.storedKey ?? ""
    /// Whether iCloud is signed in, for the chats' sync (nil until known).
    @State private var iCloud: Bool?

    var body: some View {
        Form {
            #if targetEnvironment(macCatalyst)
            MacRoleSections()
            #else
            Section {
                NavigationLink(value: SettingsPage.model) {
                    LabeledContent {
                        Text(modelStatus).monospacedDigit()
                    } label: {
                        Label(store.model.name, systemImage: Mode.device.symbol)
                    }
                }
                NavigationLink(value: SettingsPage.mac) {
                    LabeledContent {
                        Text(MacLink.isConfigured ? mac.computerName : "Not Paired")
                    } label: {
                        Label("Mac", systemImage: "desktopcomputer")
                    }
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Lantern answers on this \(Device.name), with no connection needed. Pair your Mac to use its larger model too.")
            }
            #endif

            Section {
                SecureField("Tavily API Key", text: $searchKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: searchKey) { _, key in WebSearcher.setKey(key) }
            } header: {
                Text("Web Search")
            } footer: {
                Text("With your own key from [tavily.com](https://tavily.com), a chat can look things up: turn on Search the Web where you pick its model. Searches go from this \(Device.name) straight to Tavily, and the key stays on it.")
            }

            Section {
                NavigationLink(value: SettingsPage.personalization) {
                    LabeledContent {
                        Text(customPrompt.isEmpty || Engine.customInstructions == nil ? "Default" : "Custom")
                    } label: {
                        Label("Instructions", systemImage: "text.quote")
                    }
                }
            } footer: {
                Text("What the model is told at the start of every new chat.")
            }

            Section {
            } footer: {
                VStack(spacing: 4) {
                    if iCloud == false {
                        Text("Chats stay on this \(Device.name). Sign in to iCloud to have them on your other devices too.")
                            .padding(.bottom, 6)
                    }
                    Text("Lantern \(Self.version)")
                    if let expiry = BuildExpiry.date {
                        Text("This build stops opening on \(expiry.formatted(date: .long, time: .omitted)). Update it in TestFlight before then.")
                            .foregroundStyle(BuildExpiry.isSoon ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        #if !targetEnvironment(macCatalyst)  // a window of its own on the Mac
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        #endif
        .task { iCloud = await ChatStore.signedIn() }
    }

    private var modelStatus: String {
        if store.isReady, !store.hasUpgrade { return "Ready" }
        switch store.state {
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .paused: return "Paused"
        case .failed: return "Needs Attention"
        default: return store.isReady ? "Update Available" : "Not Downloaded"
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }
}
