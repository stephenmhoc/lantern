import Foundation
import LlamaKit

// swift run lantern-smoke <model.gguf> [--lazy] [--f16] [--think] [--stop] [--state] [prompt]
//     [--draft <mtp.gguf> [--draft-max n]] [--batch n] [--temp t | --qwen-sampling] [--second <text>]
// swift run lantern-smoke <model.gguf> --template | --render
// swift run lantern-smoke <model.gguf> --bench [--verbose] [--draft <mtp.gguf>] [--batch n]
// swift run lantern-smoke <model.gguf> --mmproj <mmproj.gguf> --image <file> [--lazy] [--f16] [--draft <mtp.gguf>]
//
// --image asks about an image, then a text follow-up, then a retry of the follow-up: the image must
// be encoded once and its positions reused after that.
//
// Two turns, so the second shows whether the cache was extended. --stop also stops a reply after
// 10 pieces first and checks the next generation still runs in full. --state checks saved state:
// the second turn is repeated after reloading the model from the first turn's checkpoint and must
// match byte for byte, then after a stopped reply and as a retry, which must not re-read the chat.
// --draft drafts with an MTP model (Gemma 4's mtp-gemma-4-*-it.gguf); greedy output must not change.
// --render prints the hand-written template's renders as JSON lines, to compare with the Jinja.
// --bench reads a ~3,100-token prompt and a short one, 256 tokens each: first token is the honest
// prompt time (the prompt's own figure stops before the GPU has finished).
let args = Array(CommandLine.arguments.dropFirst().dropFirst())
guard CommandLine.arguments.count > 1 else {
    print("usage: lantern-smoke <model.gguf> [--lazy] [--f16] [--think] [--stop] [--state] [--draft <mtp.gguf>] [prompt]")
    print("       lantern-smoke <model.gguf> --template | --render | --bench")
    exit(2)
}
let path = CommandLine.arguments[1]
func value(after flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}
if args.contains("--template") {
    print(LlamaModel.rawTemplate(path: path) ?? "(no template)")
    exit(0)
}
if args.contains("--render") {
    // Renders a few conversations with the hand-written template, as JSON lines, for comparing
    // against the GGUF's Jinja (enable_thinking = thinking, add_generation_prompt = true).
    let sys = ChatMessage(role: .system, content: "  You are Lantern.\nToday is Monday.  ")
    let cases: [[ChatMessage]] = [
        [.init(role: .user, content: "Hi")],
        [sys, .init(role: .user, content: " What's 2+2? \n")],
        [sys, .init(role: .user, content: "One"), .init(role: .assistant, content: "\nFirst answer.\n"),
         .init(role: .user, content: "Two"), .init(role: .assistant, content: "Second <b>answer</b>"),
         .init(role: .user, content: "<file name=\"a.txt\">x\ny</file>\n\nThree")],
    ]
    for messages in cases {
        for thinking in [Thinking.off, .high] {
            guard let r = LlamaModel.renderedPrompt(path: path, messages, thinking: thinking) else { exit(1) }
            let json: [String: Any] = [
                "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                "thinking": thinking != .off, "prompt": r.prompt, "systemPrefix": r.systemPrefix ?? NSNull(),
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        }
    }
    exit(0)
}
let firstPrompt = args.enumerated().first { !$0.element.hasPrefix("--") && ($0.offset == 0 || !["--second", "--mmproj", "--image", "--draft", "--draft-max", "--batch", "--temp"].contains(args[$0.offset - 1])) }?.element ?? "In two sentences: how do I purify water if the power is out?"
let thinking: Thinking = args.contains("--think") ? .low : .off
// Greedy unless --temp is given (--qwen-sampling: Qwen 3.5's recommended settings).
let sampling = args.contains("--qwen-sampling") ? Sampling.qwen35(thinking: thinking != .off)
    : Sampling(temperature: value(after: "--temp").flatMap(Float.init) ?? 0, topK: 40, topP: 0.95)
let options = ModelOptions(
    lazyEmbeddings: args.contains("--lazy"), f16Cache: args.contains("--f16"), draftModel: value(after: "--draft"),
    draftTokens: value(after: "--draft-max").flatMap(Int.init) ?? 3, batchSize: value(after: "--batch").flatMap(Int.init) ?? 512)
let system = ChatMessage(role: .system, content: "You are Lantern, a helpful assistant. This conversation began on Sunday, November 22, 2026.")

struct Reply {
    var text = ""
    var thinking = ""
    var stats = GenerationStats()
    var firstToken = 0.0
}

/// Returns the answer; stops reading after `stopAfter` pieces if given.
@MainActor func ask(
    _ model: LlamaModel, _ history: [ChatMessage], stopAfter: Int? = nil, checkpoint: URL? = nil, quiet: Bool = false,
    maxTokens: Int? = nil
) async throws -> Reply {
    var reply = Reply()
    var pieces = 0
    let start = Date()
    for try await event in model.generate(
        history, sampling: sampling, thinking: thinking, maxTokens: maxTokens ?? (thinking == .off ? 1500 : 3500), checkpoint: checkpoint)
    {
        switch event {
        case .reading(let p): if !quiet { print(String(format: "[reading %.0f%%]", p * 100), terminator: "") }
        case .thinking(let t):
            if reply.firstToken == 0 { reply.firstToken = Date().timeIntervalSince(start) }
            if !quiet { print("\u{1B}[2m\(t)\u{1B}[0m", terminator: "") }
            reply.thinking += t
        case .text(let t):
            if reply.firstToken == 0 { reply.firstToken = Date().timeIntervalSince(start) }
            if !quiet { print(t, terminator: "") }
            reply.text += t
        case .done(let s):
            reply.stats = s
            let drafted = s.draftedTokens > 0 ? String(format: ", drafts %d/%d kept", s.acceptedDraftTokens, s.draftedTokens) : ""
            print(String(format: "%@[%d prompt tokens (%d reused%@) first token %.2fs; %d tokens at %.1f tok/s, %@%@; footprint %@]",
                         quiet ? "" : "\n", s.promptTokens, s.reusedTokens, s.restored ? ", restored" : "", reply.firstToken,
                         s.generatedTokens, s.tokensPerSecond, s.stopReason.rawValue, drafted, MemoryStats.gb(MemoryStats.footprintBytes)))
        }
        fflush(stdout)
        pieces += 1
        if let stopAfter, pieces >= stopAfter {
            print("\n[stopped]")
            break
        }
    }
    return reply
}

@MainActor func load() throws -> LlamaModel {
    let start = Date()
    let model = try LlamaModel(path: path, options: options)
    print("loaded \(MemoryStats.gb(model.sizeBytes)) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s,",
          "template: \(model.templateName), can rewind: \(model.canRewind), drafter: \(model.hasDrafter), footprint \(MemoryStats.gb(MemoryStats.footprintBytes))")
    return model
}

@MainActor func check(_ what: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL"): \(what)")
    if !ok { exit(1) }
}


// With greedy decoding and thinking on, Qwen 3.5 can deliberate over the emoji (and other wordings)
// until it runs out of tokens, and a reply that doesn't end cleanly leaves nothing to check.
let second = value(after: "--second")
    ?? (thinking == .off ? "Now say it in one short sentence. Use an emoji." : "Thanks. Which one is quickest?")

if let projector = value(after: "--mmproj"), let imagePath = value(after: "--image") {
    let image = try Data(contentsOf: URL(fileURLWithPath: imagePath))
    do {
        let model = try load()
        let start = Date()
        try await model.loadVision(projector: projector)
        print(String(format: "vision loaded in %.1fs, footprint %@", Date().timeIntervalSince(start), MemoryStats.gb(MemoryStats.footprintBytes)))
        var history = [system, ChatMessage(role: .user, content: "What is in this picture? One sentence.", images: [image])]
        print("> (image) \(history[1].content)")
        let first = try await ask(model, history)
        check("the image was read", first.stats.promptTokens > 100 && !first.text.isEmpty)
        history.append(.init(role: .assistant, content: first.text))
        history.append(.init(role: .user, content: "What colours stand out? Answer briefly."))
        print("> \(history.last!.content)")
        let next = try await ask(model, history)
        check("the follow-up reused the image", next.stats.reusedTokens >= first.stats.promptTokens)
        print("> (retry)")
        let again = try await ask(model, history)
        check("the retry reused the image", again.stats.reusedTokens >= first.stats.promptTokens)
        print("> (no vision) counting")
        let counted = await model.countTokens(history)
        check("counting includes the image", counted >= first.stats.promptTokens - 20)
    }
    exit(0)
}
if args.contains("--bench") {
    // Speed only: a long prompt (about 3,000 tokens) read from nothing, then a 256-token answer, and
    // a short prompt with a 256-token answer. Greedy; the texts are printed in full with --verbose.
    let filler = (1...90).map { i in
        "Note \(i): the shelter on Elm Street keeps \(i * 3) blankets, \(i + 4) lanterns and water for \(i * 2) days; check it weekly."
    }.joined(separator: "\n")
    let long = [system, ChatMessage(role: .user, content: filler + "\n\nSummarise these notes in detail, as a numbered list.")]
    let short = [system, ChatMessage(role: .user, content: "Write a detailed guide to planting a vegetable garden.")]
    do {
        let model = try load()
        let quiet = !args.contains("--verbose")
        for (name, history) in [("warmup", short), ("long", long), ("short", short)] {
            print("> \(name)")
            let r = try await ask(model, history, quiet: quiet, maxTokens: 256)
            print(String(format: "BENCH %@ prompt %.0f tok/s, gen %.1f tok/s, first token %.2fs",
                         name, Double(r.stats.promptTokens - r.stats.reusedTokens) / max(r.stats.promptSeconds, 1e-6),
                         r.stats.tokensPerSecond, r.firstToken))
            if !quiet { print(r.text) }
        }
    }
    exit(0)
}
if args.contains("--state") {
    let checkpoint = URL.temporaryDirectory.appending(path: "lantern-smoke-\(getpid())")
    defer { try? FileManager.default.removeItem(at: checkpoint) }
    var history = [system, ChatMessage(role: .user, content: firstPrompt)]
    var expected = Reply()
    var firstReply = Reply()
    do {
        let model = try load()
        await model.prepare([system], thinking: thinking, checkpoint: checkpoint)
        print("\n> \(firstPrompt)")
        firstReply = try await ask(model, history, checkpoint: checkpoint, quiet: true)
        check("first turn continued the primed system prompt", firstReply.stats.reusedTokens > 0)
        history.append(.init(role: .assistant, content: firstReply.text))
        print("> \(second)")
        expected = try await ask(model, history + [.init(role: .user, content: second)], checkpoint: checkpoint, quiet: true)
        if !(model.canRewind && thinking != .off) {  // Gemma re-renders with thinking on
            check("second turn appended", expected.stats.reusedTokens > firstReply.stats.promptTokens)
        }
    }
    do {
        // A fresh load, as after the app was closed: the chat is reopened from the second turn's
        // checkpoint, then retried from the first turn's.
        let model = try load()
        if model.canRewind && thinking != .off {
            print("(this model re-renders with thinking on, so nothing is saved for it)")
        } else {
            // States used to sit in the chat's directory itself; now each model has its own. The
            // ones saved above are adopted into a model directory and reopened from there.
            let legacy = checkpoint
            let checkpoint = legacy.appending(path: "model")
            model.adoptLegacyState(from: legacy, into: checkpoint)
            let full = history + [.init(role: .user, content: second), .init(role: .assistant, content: expected.text)]
            await model.prepare(full, thinking: thinking, checkpoint: checkpoint)
            check("reopening the chat loaded its state", model.tokensInContext > 0)
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: legacy.path)) ?? []).filter { $0 != "model" }
            check("the legacy state was adopted, nothing left behind", left.isEmpty
                  && FileManager.default.fileExists(atPath: checkpoint.appending(path: "latest.json").path))
            print("> (retry) \(second)")
            let retried = try await ask(model, history + [.init(role: .user, content: second)], checkpoint: checkpoint, quiet: true)
            check("retry didn't re-read the chat", retried.stats.reusedTokens > firstReply.stats.promptTokens)
            if !model.canRewind {
                check("retry restored the turn before", retried.stats.restored)
                check("retry after restore is byte-identical", retried.text == expected.text && retried.thinking == expected.thinking)
            }
            print("> (stopped, then) Thanks. And in French?")
            let stopped = try await ask(model, history + [.init(role: .user, content: "Count slowly from 1 to 50.")],
                                        stopAfter: 6, checkpoint: checkpoint, quiet: true)
            var after = history + [.init(role: .user, content: "Count slowly from 1 to 50.")]
            if !stopped.text.isEmpty { after.append(.init(role: .assistant, content: stopped.text)) }
            after.append(.init(role: .user, content: "Thanks. Now the water answer again, in French."))
            let next = try await ask(model, after, checkpoint: checkpoint, quiet: true)
            check("a message after a stopped reply didn't re-read the chat", next.stats.reusedTokens >= firstReply.stats.promptTokens)
            print("> (new chat) What is 17 * 23?")
            // The first chat started from nothing snapshots the system prompt (a model that can
            // rewind just keeps the shared prefix); the next one starts from it.
            _ = try await ask(model, [system, .init(role: .user, content: "What is 17 * 23? Answer briefly.")], quiet: true)
            print("> (another new chat) Name a primary colour.")
            let other = try await ask(model, [system, .init(role: .user, content: "Name a primary colour.")], quiet: true)
            check("a new chat reused the system prompt", other.stats.reusedTokens > 0)
        }
    }
    exit(0)
}

// Scoped so the model is freed before exit; llama.cpp's Metal teardown asserts on live resources.
do {
    let model = try load()
    if args.contains("--stop") {
        print("\n> (stopping after 10 pieces) \(firstPrompt)")
        _ = try await ask(model, [.init(role: .user, content: firstPrompt)], stopAfter: 10)
    }
    var history: [ChatMessage] = []
    for prompt in [firstPrompt, second] {
        print("\n> \(prompt)")
        history.append(.init(role: .user, content: prompt))
        history.append(.init(role: .assistant, content: try await ask(model, history).text))
    }
}
