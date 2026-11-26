import SwiftUI

/// The composer's model button opens this: a sheet on iPhone (half height, pulls up to full), a
/// popover on iPad. The two models (this device's and the Mac's), then how the chat answers:
/// Think First and Search the Web, a switch each. Picking a model closes it.
///
/// The answer menu's Compare With uses it too (`ComparePicker`), with the thinking switch for the
/// second answer and no search switch.
struct ModelPicker: View {
    struct Row: Identifiable {
        let choice: ModelChoice
        var title: String
        var symbol: String
        /// Where it runs, or why it can't be picked.
        var note: String
        var enabled: Bool
        var current: Bool
        /// Leads somewhere (Settings) rather than being picked.
        var opens = false
        var id: ModelChoice { choice }
    }

    var title = "Model"
    /// Compare With closes with Cancel: picking a model is what starts it.
    var cancels = false
    /// Read while drawing, so the rows follow the engine and the chat (the download's progress,
    /// the Mac answering) and the switch while the picker is open.
    let rows: (_ thinking: Bool) -> [Row]
    let thinking: Binding<Bool>
    var thinkingFooter = "The model reasons before it answers: slower, but better at hard questions."
    /// Nil where searching isn't offered (Compare With).
    var search: Binding<Bool>?
    /// Opens Settings, where the Tavily key goes.
    var setUpSearch: (() -> Void)?
    let select: (ModelChoice) -> Void
    let close: () -> Void
    @Environment(ModelStore.self) private var store
    @Environment(MacLink.self) private var mac

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows(thinking.wrappedValue)) { row($0) }
                }
                Section {
                    Toggle(isOn: thinking) { Label("Think First", systemImage: "lightbulb") }
                } footer: {
                    Text(thinkingFooter)
                }
                if let search {
                    Section {
                        if WebSearcher.hasKey {
                            Toggle(isOn: search) { Label("Search the Web", systemImage: "globe") }
                        } else {
                            // No key yet: the row leads to where it goes, rather than a switch that does nothing.
                            Button { setUpSearch?() } label: {
                                LabeledContent {
                                    HStack(spacing: 4) {
                                        Text("Set Up")
                                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                                    }
                                    .foregroundStyle(Color(.secondaryLabel))
                                } label: {
                                    Label { Text("Search the Web").foregroundStyle(Color(.label)) } icon: { Image(systemName: "globe") }
                                }
                            }
                            .accessibilityHint("Opens Settings to add a Tavily API key")
                        }
                    } footer: {
                        Text(WebSearcher.hasKey
                             ? "The model looks things up when a question needs it, and shows its sources."
                             : "Searching uses your own Tavily API key. Add it in Settings.")
                    }
                }
            }
            .toggleStyle(.switch)  // the Mac's checkbox reads as a form, not a setting of the chat
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
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
                    .font(.title3)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).foregroundStyle(Color(.label))
                    Text(row.note).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                }
                Spacer(minLength: 8)
                if row.current {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                } else if row.opens {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                        .accessibilityHidden(true)
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
    let rows: (_ thinking: Bool) -> [ModelPicker.Row]
    let select: (ModelChoice, _ thinking: Bool) -> Void
    let close: () -> Void
    @State private var thinking: Bool

    init(answerThought: Bool, rows: @escaping (_ thinking: Bool) -> [ModelPicker.Row],
         select: @escaping (ModelChoice, _ thinking: Bool) -> Void, close: @escaping () -> Void) {
        self.answerThought = answerThought
        self.rows = rows
        self.select = select
        self.close = close
        _thinking = State(initialValue: answerThought)
    }

    var body: some View {
        ModelPicker(
            title: "Compare With",
            cancels: true,
            rows: rows,
            thinking: $thinking,
            thinkingFooter: """
                For the second answer. This one was written with thinking \(answerThought ? "on" : "off"): \
                switch it to compare the same model \(answerThought ? "without" : "with") it.
                """,
            select: { select($0, thinking) },
            close: close)
    }
}
