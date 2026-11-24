import SwiftUI
import UIKit

/// Two answers to the same question, from two models, with how each was made. A comparison is a
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
    @State private var side: CompareMetricsView.Side

    init(conversation: Conversation, replyID: UUID, startOnB: Bool = false) {
        self.conversation = conversation
        self.replyID = replyID
        _side = State(initialValue: startOnB ? .b : .a)
    }

    /// One of the two answers, as shown here.
    struct Answer {
        var content: String
        var error: String?
        var metrics: ReplyMetrics?
        var title: String
        var mode: Mode
        /// Its index in the reply's `allVersions`, for voting and continuing. Nil while it's written.
        var index: Int?
        var isRunning = false
        var isPreferred: Bool { metrics?.preferred == true }
    }

    private struct Pair {
        var a: Answer
        var b: Answer
        var question: String
        /// Votes and Continue only make sense on the chat's last reply, once both answers are in.
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

    /// iPad: the two answers in columns that scroll on their own, the table below.
    private func sideBySide(_ pair: Pair) -> some View {
        GeometryReader { geometry in
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
                Divider()
                ViewThatFits(in: .vertical) {
                    metrics(pair).padding(20)
                    ScrollView { metrics(pair).padding(20) }
                }
                .frame(maxHeight: geometry.size.height * 0.42)
                .background(Color(.secondarySystemBackground))
            }
        }
    }

    private func column(_ answer: Answer, letter: String, pair: Pair) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                answerHeader(answer, letter: letter)
                if pair.canAct, answer.index != nil {
                    HStack(spacing: 8) {
                        preferButton(answer, letter: letter)
                        continueButton(answer, letter: letter)
                    }
                }
                answerBody(answer)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    /// iPhone: one answer at a time, then the table; its actions stay at the bottom.
    private func oneAtATime(_ pair: Pair) -> some View {
        let answer = side == .a ? pair.a : pair.b
        let letter = side == .a ? "A" : "B"
        return ScrollViewReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                questionHeader(pair.question)
                Picker("Answer", selection: $side) {
                    Text("A").tag(CompareMetricsView.Side.a).accessibilityLabel("A, \(pair.a.title)")
                    Text("B").tag(CompareMetricsView.Side.b).accessibilityLabel("B, \(pair.b.title)")
                }
                .pickerStyle(.segmented)
                answerHeader(answer, letter: letter)
                answerBody(answer)
                Divider().padding(.vertical, 4)
                metrics(pair).id("metrics")
            }
            .padding()
        }
        #if DEBUG
        // -ui compare:metrics (or compare:b:metrics): the table, for checking it without scrolling.
        .task {
            guard DebugLaunch.ui?.hasSuffix(":metrics") == true else { return }
            try? await Task.sleep(for: .seconds(0.5))
            proxy.scrollTo("metrics", anchor: .top)
        }
        #endif
        }
        .safeAreaInset(edge: .bottom) {
            if pair.canAct, answer.index != nil {
                HStack(spacing: 10) {
                    preferButton(answer, letter: letter)
                    Spacer(minLength: 0)
                    continueButton(answer, letter: letter)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
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
            if answer.isPreferred {
                Image(systemName: "hand.thumbsup.fill")
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Preferred")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Answer \(letter), \(answer.title)\(answer.isPreferred ? ", preferred" : "")")
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

    private func metrics(_ pair: Pair) -> some View {
        CompareMetricsView(a: pair.a.metrics ?? placeholder(pair.a), b: pair.b.metrics ?? placeholder(pair.b))
    }

    /// An answer without metrics still names its model in the table's header.
    private func placeholder(_ answer: Answer) -> ReplyMetrics {
        ReplyMetrics(modeRaw: answer.mode.rawValue, modelTitle: answer.title)
    }

    private func preferButton(_ answer: Answer, letter: String) -> some View {
        Button {
            guard let index = answer.index else { return }
            engine.vote(in: conversation, preferring: answer.isPreferred ? nil : index)
        } label: {
            Label(answer.isPreferred ? "Preferred \(letter)" : "Prefer \(letter)",
                  systemImage: answer.isPreferred ? "hand.thumbsup.fill" : "hand.thumbsup")
        }
        .buttonStyle(.bordered)
        .tint(answer.isPreferred ? .primary : .secondary)
        .controlSize(.regular)
        .accessibilityLabel("Prefer \(letter)")
        .accessibilityValue(answer.isPreferred ? "Selected" : "")
        .accessibilityHint(answer.isPreferred ? "Clears the vote" : "")
    }

    private func continueButton(_ answer: Answer, letter: String) -> some View {
        Button {
            guard let index = answer.index else { return }
            engine.continueWith(in: conversation, version: index)
            dismiss()
        } label: {
            Label("Continue With \(letter)", systemImage: "arrow.turn.down.right")
                // Dark on the amber fill: white on it is about 2.3:1.
                .foregroundStyle(.black)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
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
            let title = running.next?.title ?? (mode == .mac ? MacLink.displayName(engine.live?.macModel ?? "") : mode.title)
            let b = Answer(content: "", metrics: nil, title: title, mode: mode, index: nil, isRunning: true)
            return Pair(a: answer(list[ai], index: ai), b: b, question: question, canAct: false)
        }
        guard let c = reply.comparison else { return nil }
        return Pair(a: answer(c.versions.0, index: c.a), b: answer(c.versions.1, index: c.b),
                    question: question, canAct: isLast && reply.finished)
    }

    private func answer(_ v: ReplyVersion, index: Int) -> Answer {
        let model = conversation.model(of: v.metrics, footnote: v.footnote, macModels: engine.mac.models)
        let mode = model.mode
        let title = v.metrics?.modelTitle ?? ChatSearch.modelName(v.footnote) ?? model.title
        return Answer(content: v.content, error: v.error, metrics: v.metrics, title: title,
                      mode: mode, index: index)
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
