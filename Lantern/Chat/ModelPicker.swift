import SwiftUI

/// The composer's model button opens this: a sheet on iPhone (half height, scrolls, pulls up to
/// full), a popover on iPad. Thinking is a switch at the top: every model either thinks or doesn't
/// (`Thinking.low` and `.high` do the same), so there's no level to pick. Then the models on this
/// device and on the computer, one row each; picking one closes it.
///
/// It replaced a UIMenu, which put Thinking in a submenu at the very end of a list too long for
/// the space above the composer.
struct ModelPicker: View {
    struct Row: Identifiable {
        let choice: ModelChoice
        let title: String
        let symbol: String
        /// Only when it says something: why a model can't be picked, or the computer can't be reached.
        let note: String?
        let enabled: Bool
        let current: Bool
        var id: ModelChoice { choice }
    }

    struct Group {
        let title: String
        let rows: [Row]
    }

    /// Read while drawing, so the rows follow the engine and the chat (a model finishing its
    /// download, the computer answering) while the picker is open.
    let groups: () -> [Group]
    /// Nil when the chat's model doesn't think at all (Apple Intelligence).
    let thinking: Binding<Bool>?
    let select: (ModelChoice) -> Void
    let getModels: (() -> Void)?
    let close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let thinking {
                    Section {
                        Toggle(isOn: thinking) {
                            Label("Think First", systemImage: "lightbulb")
                        }
                    } footer: {
                        Text("The model reasons before it answers: slower, but better at hard questions.")
                    }
                }
                ForEach(Array(groups().enumerated()), id: \.offset) { _, group in
                    Section(group.title) {
                        ForEach(group.rows) { row($0) }
                    }
                }
                if let getModels {
                    Section {
                        Button("Get Models…", systemImage: "arrow.down.circle", action: getModels)
                    }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
            }
        }
    }

    private func row(_ row: Row) -> some View {
        Button { select(row.choice) } label: {
            HStack(spacing: 12) {
                // Explicit colours: in a list button, `.primary` and `.secondary` take the amber tint.
                Image(systemName: row.symbol)
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).foregroundStyle(Color(.label))
                    if let note = row.note {
                        Text(note).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                    }
                }
                Spacer(minLength: 8)
                if row.current {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .disabled(!row.enabled)
        .opacity(row.enabled ? 1 : 0.45)
        .accessibilityAddTraits(row.current ? .isSelected : [])
    }
}
