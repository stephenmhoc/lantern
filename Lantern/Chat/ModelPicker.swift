import SwiftUI

/// The composer's model button opens this: a sheet on iPhone (half height, scrolls, pulls up to
/// full), a popover on iPad. Thinking is a switch at the top: every model either thinks or doesn't
/// (`Thinking.low` and `.high` do the same), so there's no level to pick. Then the models on this
/// device and on the computer, one row each; picking one closes it.
///
/// It replaced a UIMenu, which put Thinking in a submenu at the very end of a list too long for
/// the space above the composer. The answer menu's Compare With uses it too (`ComparePicker`), with
/// the switch for the second answer.
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

    var title = "Model"
    /// Compare With closes with Cancel: picking a model is what starts it.
    var cancels = false
    /// Read while drawing, so the rows follow the engine and the chat (a model finishing its
    /// download, the computer answering) and the switch while the picker is open.
    let groups: (_ thinking: Bool) -> [Group]
    /// Nil when the chat's model doesn't think at all (Apple Intelligence).
    let thinking: Binding<Bool>?
    var thinkingFooter = "The model reasons before it answers: slower, but better at hard questions."
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
                        Text(thinkingFooter)
                    }
                }
                ForEach(Array(groups(thinking?.wrappedValue ?? false).enumerated()), id: \.offset) { _, group in
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if cancels {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
                }
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

/// Compare With: which model writes the second answer, and whether it thinks. The switch starts
/// as the first answer was made; the first answer's own model can be picked once it's flipped.
struct ComparePicker: View {
    /// Whether the answer being compared was written with thinking.
    let answerThought: Bool
    let groups: (_ thinking: Bool) -> [ModelPicker.Group]
    let select: (ModelChoice, _ thinking: Bool) -> Void
    let close: () -> Void
    @State private var thinking: Bool

    init(answerThought: Bool, groups: @escaping (_ thinking: Bool) -> [ModelPicker.Group],
         select: @escaping (ModelChoice, _ thinking: Bool) -> Void, close: @escaping () -> Void) {
        self.answerThought = answerThought
        self.groups = groups
        self.select = select
        self.close = close
        _thinking = State(initialValue: answerThought)
    }

    var body: some View {
        ModelPicker(
            title: "Compare With",
            cancels: true,
            groups: groups,
            thinking: $thinking,
            thinkingFooter: """
                For the second answer. This one was written with thinking \(answerThought ? "on" : "off"): \
                switch it to compare the same model \(answerThought ? "without" : "with") it.
                """,
            select: { select($0, thinking) },
            getModels: nil,
            close: close)
    }
}
