import Foundation
import LlamaKit

// swift run lantern-smoke <model.gguf> [--lazy] [--think] [--stop] [--template] [prompt]
// Two turns, so the second shows whether the cache was extended. --stop also stops a reply after
// 10 pieces first and checks the next generation still runs in full.
var args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else {
    print("usage: lantern-smoke <model.gguf> [--lazy] [--think] [--stop] [--template] [prompt]")
    exit(2)
}
args.removeFirst()
if args.contains("--template") {
    print(LlamaModel.rawTemplate(path: path) ?? "(no template)")
    exit(0)
}
let firstPrompt = args.first { !$0.hasPrefix("--") } ?? "In two sentences: how do I purify water if the power is out?"
let thinking: Thinking = args.contains("--think") ? .low : .off

/// Returns the answer text; stops reading after `stopAfter` pieces if given.
func ask(_ model: LlamaModel, _ history: [ChatMessage], stopAfter: Int? = nil) async throws -> String {
    var reply = ""
    var pieces = 0
    for try await event in model.generate(history, sampling: Sampling(temperature: 0), thinking: thinking, maxTokens: 1500) {
        switch event {
        case .reading(let p): print(String(format: "[reading %.0f%%]", p * 100), terminator: "")
        case .thinking(let t): print("\u{1B}[2m\(t)\u{1B}[0m", terminator: "")
        case .text(let t):
            print(t, terminator: "")
            reply += t
        case .done(let s):
            print(String(format: "\n[%d prompt tokens (%d reused) in %.2fs; %d tokens at %.1f tok/s; footprint %@]",
                         s.promptTokens, s.reusedTokens, s.promptSeconds, s.generatedTokens, s.tokensPerSecond,
                         MemoryStats.gb(MemoryStats.footprintBytes)))
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

// Scoped so the model is freed before exit; llama.cpp's Metal teardown asserts on live resources.
do {
    let loadStart = Date()
    let model = try LlamaModel(path: path, lazyExperts: args.contains("--lazy"))
    print("loaded \(MemoryStats.gb(model.sizeBytes)) in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s,",
          "template: \(model.templateName), footprint \(MemoryStats.gb(MemoryStats.footprintBytes))")

    if args.contains("--stop") {
        print("\n> (stopping after 10 pieces) \(firstPrompt)")
        _ = try await ask(model, [.init(role: .user, content: firstPrompt)], stopAfter: 10)
    }
    var history: [ChatMessage] = []
    for prompt in [firstPrompt, "Now say it in one short sentence. Use an emoji."] {
        print("\n> \(prompt)")
        history.append(.init(role: .user, content: prompt))
        history.append(.init(role: .assistant, content: try await ask(model, history)))
    }
}
