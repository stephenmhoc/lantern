# Lantern

An LLM that keeps working in an internet or power outage. iPhone and iPad, iOS 18.1+, Swift 6 with
MainActor default isolation, SwiftData. Three modes behind one chat:

- **Fast**: Gemma 4 E2B on device, fully in memory.
- **Smart**: Inkling 2 Mini on device. Bigger than the app's memory limit, so it's memory-mapped
  with `lazy_mode` on and the OS pages MoE experts in from storage (clean pages don't count
  against the app's footprint).
- **Mac**: Ollama on the Mac Studio, home network first (works with the internet down), tailnet second.

## Layout

- `Packages/LlamaKit`: the llama.cpp wrapper (`LlamaModel`, hand-written `ChatTemplate`s) and the
  `lantern-smoke` Mac CLI.
- `Lantern/Engine`: `Engine` owns the one generation that can run at a time (send, stop, retry,
  backgrounding, idle unload, model self-test); `ModelStore` downloads; `MacLink` talks to Ollama.
- `Lantern/Chat`: the chat screen, in UIKit. `Lantern/Views`: everything else, in SwiftUI.

## Commands

```sh
scripts/fetch-llama.sh      # pinned llama.cpp xcframework into Vendor/ (gitignored)
xcodegen generate           # after changing project.yml or adding files
cd Packages/LlamaKit && swift build -c release && .build/release/lantern-smoke ../../Models/<file>.gguf [--think] [--stop] [--lazy]
                            # two-turn check of a GGUF on the Mac through the app's own wrapper
```

The official xcframework has no simulator slice. For the simulator, build llama.cpp's
`build-xcframework.sh` at the pinned tag (needs CMake) into `Vendor/build-apple/`; in the
simulator llama.cpp runs on the CPU, since the simulator's Metal driver can't map its buffers.
`scripts/fetch-tailscale.sh` builds TailscaleKit (needs Go) for signing into the tailnet; without it
`Tailnet` compiles out.

## Rules

- **SwiftUI where it can be, UIKit for the important pieces.** The chat transcript and message box
  are UIKit (`ChatViewController`): streaming into a cell without reloading it, selectable answers
  with data detectors, following the bottom only while the user is there, hardware-keyboard
  commands. Sidebar, sheets, the status strip and settings stay SwiftUI.
- **Never update UI per token.** `Engine.live` (a plain `LiveReply`) collects tokens; the chat screen
  reads it on a ~15 Hz display link. SwiftData is written when a turn starts and ends and every ~5 s.
- **One generation at a time, owned by `Engine`.** Views never hold the task. Stop cancels the task;
  the stream's termination is what stops llama.cpp or the Ollama request.
- **llama.cpp is pinned** in `scripts/fetch-llama.sh`. Inkling needs a build after PR #32704 and
  Unsloth's `Mainline_Support/*.gguf_file` files (saved as `.gguf`); the root GGUFs are a different
  layout. Run the smoke test on both models (with `--think` and `--stop`) before moving the pin.
- **Chat templates are hand-written** in `ChatTemplate.swift` because llama.cpp's C helper has no
  Jinja. Check them against `lantern-smoke <file> --template` when adding a model.
- **Never rewind the KV cache on Inkling.** Its short-conv layers can't roll back state, so
  `llama_memory_seq_rm` fails and the whole chat is reprocessed. `LlamaModel` appends the next turn
  after the model's own turn-end token instead; history passed back must be byte-identical to what
  was streamed. Gemma with thinking on re-renders instead, because its template drops old thinking.
- **One on-device model loaded at a time.** `Engine.load` frees the old one first.
- **The system prompt is neutral.** Outages are why Lantern exists, not something the models should
  assume: no disaster or emergency framing in the prompt, starters or copy.
- **Offline first.** Nothing may need the network to launch or to open an existing chat.
- Distributed by TestFlight with a monthly rebuild, like Quill. A build stops launching 90 days after
  upload; Readiness shows the date from `LanternBuildDate`, stamped into Info.plist at build time.
