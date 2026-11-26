import SwiftUI
import UIKit

/// Two answers to the same question, from two models (or one, with and without thinking), and a
/// way to go on with either. A comparison is a
/// second answer to the last question of an ordinary chat: both sit in the reply's versions and
/// share a `ReplyMetrics.compareID` (`StoredMessage.comparison`). Side by side on iPad, one at a
/// time behind an A | B picker on iPhone. Presented from `ChatViewController`.
struct CompareView: View {
    let conversation: Conversation
    /// The reply holding the pair. While B is still being written the last reply is used.
    let replyID: UUID

    @Environment(Engine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var side = Side.a

    enum Side { case a, b }

    /// One of the two answers, as shown here.
    struct Answer {
        var content: String
        var error: String?
        var title: String
        var mode: Mode
        /// Its index in the reply's `allVersions`, for continuing. Nil while it's written.
        var index: Int?
        var isRunning = false
    }

    private struct Pair {
        var a: Answer
        var b: Answer
        var question: String
        /// Continue only makes sense on the chat's last reply, once both answers are in.
        var canAct: Bool
    }

    var body: some View {
        NavigationStack {
            Group {
                if let pair {
                    if sizeClass == .regular {
                        sideBySide(pair)
                    } else {
                        oneAtATime(pair)
                    }
                } else {
                    ContentUnavailableView("No comparison", systemImage: "rectangle.split.2x1",
                                           description: Text("This answer hasn't been compared with another model."))
                }
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { closeButton }
            }
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if #available(iOS 26, *) {
            Button(role: .close) { dismiss() }
        } else {
            Button("Close", systemImage: "xmark") { dismiss() }
        }
    }

    // MARK: - Layouts

    /// iPad: the two answers in columns that scroll on their own.
    private func sideBySide(_ pair: Pair) -> some View {
        VStack(spacing: 0) {
            questionHeader(pair.question)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                column(pair.a, letter: "A", pair: pair)
                Divider()
                column(pair.b, letter: "B", pair: pair)
            }
        }
    }

    private func column(_ answer: Answer, letter: String, pair: Pair) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                answerHeader(answer, letter: letter)
                answerBody(answer)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .modifier(BottomBar {
            if pair.canAct, answer.index != nil {
                continueButton(answer, letter: letter).padding(.horizontal, 20).padding(.vertical, 10)
            }
        })
    }

    /// iPhone: one answer at a time; Continue stays at the bottom.
    private func oneAtATime(_ pair: Pair) -> some View {
        let answer = side == .a ? pair.a : pair.b
        let letter = side == .a ? "A" : "B"
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                questionHeader(pair.question)
                Picker("Answer", selection: $side) {
                    Text("A").tag(Side.a).accessibilityLabel("A, \(pair.a.title)")
                    Text("B").tag(Side.b).accessibilityLabel("B, \(pair.b.title)")
                }
                .pickerStyle(.segmented)
                answerHeader(answer, letter: letter)
                answerBody(answer)
            }
            .padding()
        }
        .modifier(BottomBar {
            if pair.canAct, answer.index != nil {
                continueButton(answer, letter: letter).padding(.horizontal).padding(.vertical, 10)
            }
        })
    }

    // MARK: - Pieces

    private func questionHeader(_ question: String) -> some View {
        Text(question)
            .font(.headline)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Question: \(question)")
    }

    private func answerHeader(_ answer: Answer, letter: String) -> some View {
        HStack(spacing: 8) {
            Text(letter)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 24, minHeight: 24)
                .background(Circle().fill(Color(.tertiarySystemFill)))
                .accessibilityHidden(true)
            Label(answer.title, systemImage: answer.mode.symbol)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Answer \(letter), \(answer.title)")
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func answerBody(_ answer: Answer) -> some View {
        if answer.isRunning {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Answering…").foregroundStyle(.secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                // A few times a second, never per token: the transcript streams it too.
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let text = engine.live?.text ?? ""
                    if !text.isEmpty { MarkdownText(text: text) }
                }
            }
        } else if let error = answer.error {
            Text(error).font(.callout).foregroundStyle(.red)
        } else if answer.content.isEmpty {
            Text("No answer").foregroundStyle(.secondary)
        } else {
            MarkdownText(text: answer.content)
        }
    }

    private func continueButton(_ answer: Answer, letter: String) -> some View {
        Button {
            guard let index = answer.index else { return }
            engine.continueWith(in: conversation, version: index)
            dismiss()
        } label: {
            Text("Continue With \(letter)")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .modifier(ProminentLabel())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(engine.isBusy)
        .accessibilityHint("Shows this answer in the chat and goes on with \(answer.title)")
    }

    // MARK: - The pair

    private var pair: Pair? {
        let messages = conversation.messages
        let running = engine.comparing.flatMap { $0.conversation == conversation.persistentModelID ? $0 : nil }
        guard let i = running == nil ? messages.firstIndex(where: { $0.id == replyID })
                ?? messages.lastIndex(where: { !$0.isUser }) : messages.lastIndex(where: { !$0.isUser })
        else { return nil }
        let reply = messages[i]
        let question = messages[..<i].last(where: \.isUser).map { $0.content.isEmpty ? attachmentNames($0) : $0.content } ?? ""
        let isLast = i == messages.count - 1

        if let running, isLast {
            // B is being written: A is the earlier answer with the comparison's id.
            let (list, current) = reply.allVersions
            let others = list.indices.filter { $0 != current }
            guard let ai = others.last(where: { list[$0].metrics?.compareID == running.id }) ?? others.last else { return nil }
            let mode = engine.live?.mode ?? running.next?.mode ?? .mac
            var title = conversation.modelTitle  // the chat is on B's model and thinking while B runs
            if conversation.thinking != .off { title += " · Thinking" }
            let b = Answer(content: "", title: title, mode: mode, index: nil, isRunning: true)
            return Pair(a: answer(list[ai], index: ai), b: b, question: question, canAct: false)
        }
        guard let c = reply.comparison else { return nil }
        return Pair(a: answer(c.versions.0, index: c.a), b: answer(c.versions.1, index: c.b),
                    question: question, canAct: isLast && reply.finished)
    }

    private func answer(_ v: ReplyVersion, index: Int) -> Answer {
        let mode = v.metrics.flatMap { Mode(rawValue: $0.modeRaw) }?.current ?? conversation.mode.current
        let title = v.metrics?.labeledTitle ?? ChatSearch.modelName(v.footnote) ?? conversation.modelTitle
        return Answer(content: v.content, error: v.error, title: title, mode: mode, index: index)
    }

    private func attachmentNames(_ m: StoredMessage) -> String {
        (m.attachments ?? []).map(\.name).joined(separator: ", ")
    }
}

/// An answer's Markdown, drawn by the transcript's own renderer and text view: selectable, with
/// code blocks, tables and tappable links, at the current Dynamic Type size.
struct MarkdownText: UIViewRepresentable {
    let text: String

    final class Coordinator { var key: String? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = makeAnswerTextView()
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let size = context.environment.dynamicTypeSize
        let key = "\(size)|\(text)"
        guard key != context.coordinator.key else { return }
        context.coordinator.key = key
        let traits = view.traitCollection.modifyingTraits {
            $0.preferredContentSizeCategory = UIContentSizeCategory(size)
        }
        view.attributedText = Markdown.render(text, traits: traits)
        view.accessibilityTraits.remove(.updatesFrequently)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 320
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }
}
