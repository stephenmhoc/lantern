#if DEBUG
import Foundation
import LlamaKit
import SwiftData
import UIKit

/// `-featuretest [-smart] [-image <path>]`: a two-turn chat through `Engine` that checks what's
/// appended to a user turn (the date note, an attached file, an image) keeps the cache append-only:
/// the second turn must reuse everything the first left. Prints FEATURETEST lines
/// (simctl launch --console). Uses its own in-memory store, so no chats are touched.
extension Engine {
    func runFeatureTest() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let container = try? ModelContainer(
            for: Conversation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)) else { return }
        let context = container.mainContext
        let mode: Mode = arguments.contains("-smart") ? .smart : .fast
        let chat = Conversation(mode: mode)
        // Begun three days ago: the first question gets a date note, the second doesn't.
        chat.created = Date(timeIntervalSinceNow: -3 * 86_400)
        chat.systemPrompt = Engine.systemPrompt(now: chat.created)
        context.insert(chat)
        func idle() async {
            repeat { try? await Task.sleep(for: .milliseconds(200)) } while isBusy
        }
        func report(_ label: String) {
            let m = chat.messages.last
            let s = lastStats
            print("FEATURETEST \(label): \(m?.content.prefix(80) ?? "") | error: \(m?.error ?? "none")",
                  "| prompt \(s?.promptTokens ?? 0), reused \(s?.reusedTokens ?? 0)")
        }
        func check(_ what: String, _ ok: Bool) { print("FEATURETEST \(ok ? "PASS" : "FAIL"): \(what)") }

        let note = Attachment(name: "keeper.txt", text: "Lighthouse log, 3 March.\nThe keeper's cat is called Biscuit.")
        send("What is the cat called? One short sentence.", attachments: [note], in: chat)
        await idle()
        report("file turn")
        let first = lastStats
        let question = chat.messages[chat.messages.count - 2]
        check("the first question carries a date note", question.dateNote != nil)
        check("the file is in the turn", question.chatMessage?.content.contains("<file name=\"keeper.txt\">") == true)
        print("FEATURETEST turn as sent: \(question.chatMessage?.content.debugDescription ?? "")")

        send("And what was the date of the log entry?", in: chat)
        await idle()
        report("follow-up")
        check("the follow-up has no second date note", chat.messages[chat.messages.count - 2].dateNote == nil)
        if let first, let next = lastStats {
            check("the follow-up appended to the cache", next.reusedTokens >= first.promptTokens + first.generatedTokens - 2)
        }

        if let i = arguments.firstIndex(of: "-image"), arguments.indices.contains(i + 1),
           let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[i + 1])),
           let image = UIImage(data: data).flatMap({ AttachmentReader.attachment($0, name: "picture.jpg") }) {
            check("this mode can see images", canSeeImages(mode))
            let before = lastStats
            send("What is in this picture? One sentence.", attachments: [image], in: chat)
            await idle()
            report("image turn")
            let imageTurn = lastStats
            if let before, let imageTurn {
                check("the image turn reused the chat before it", imageTurn.reusedTokens >= before.promptTokens)
            }
            send("What colour is it mostly? A few words.", in: chat)
            await idle()
            report("after the image")
            if let imageTurn, let next = lastStats {
                check("the image was not encoded again", next.reusedTokens >= imageTurn.promptTokens)
            }
        }
        forgetState(for: chat)
        print("FEATURETEST done")
    }
}
#endif
