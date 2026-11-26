import SwiftUI

/// Settings > Personalization: the instructions every model gets at the start of a new chat, in
/// place of the default ones. The date the chat began always follows them. Chats keep the prompt
/// they started with (it's the start of every cache and saved state), so a change shows in new chats.
struct PersonalizationView: View {
    @AppStorage(Engine.customPromptKey) private var customPrompt = ""
    /// What's in the editor: the custom instructions, or the default ones to start from.
    @State private var text = Engine.customInstructions ?? Engine.defaultInstructions
    @FocusState private var editing: Bool

    private var isDefault: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == Engine.defaultInstructions
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .focused($editing)
                    .frame(minHeight: 180)
                    .onChange(of: text) { _, new in
                        // Empty or the default as it was: back to the default (stored as empty).
                        customPrompt = isDefault ? "" : new.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
            } header: {
                Text("Instructions")
            } footer: {
                Text("Every model gets these at the start of a new chat, followed by the day it began. Tell them how to answer, what to call you, or what to keep in mind. Chats you already have keep the instructions they started with.")
            }

            if !isDefault {
                Section {
                    Button("Use the Default Instructions") {
                        text = Engine.defaultInstructions
                        editing = false
                    }
                }
            }

            Section {
                Text(Engine.systemPrompt())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("A new chat starts with")
            }
        }
        .navigationTitle("Personalization")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editing {
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") { editing = false }
                    }
                }
            }
        }
    }
}
