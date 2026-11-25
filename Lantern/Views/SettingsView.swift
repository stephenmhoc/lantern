import LlamaKit
import SwiftUI

/// Pages pushed inside the Settings sheet.
enum SettingsPage: Hashable {
    case readiness
}

struct SettingsView: View {
    @Environment(MacLink.self) private var mac
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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
                Text(Engine.systemPrompt())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("System prompt")
            } footer: {
                Text("What every model is told at the start of a new chat. Each chat keeps the prompt it started with.")
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
}
