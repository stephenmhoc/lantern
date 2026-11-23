# Lantern

An LLM that keeps working in an internet or power outage. iPhone and iPad, iOS 18.1+, Swift 6 with
MainActor default isolation, SwiftData. Three modes behind one chat:

- **Fast**: Gemma 4 E2B on device, fully in memory.
- **Smart**: Inkling 2 Mini on device. Bigger than the app's memory limit, so it's memory-mapped
  and the OS pages MoE experts in from storage (clean pages don't count against the app's
  footprint). mmap alone does this: llama.cpp's `lazy_mode` only covers per-layer embedding
  tables, which Gemma has and Inkling doesn't.
- **Mac**: Ollama on the Mac Studio, home network first (works with the internet down), tailnet second.

## Layout

- `Packages/LlamaKit`: the llama.cpp wrapper (`LlamaModel`, hand-written `ChatTemplate`s),
  `MetalConverter` (rewrites tensors Metal can't run) and the `lantern-smoke` Mac CLI.
- `Lantern/Engine`: `Engine` owns the one generation that can run at a time (send, stop, retry,
  `prepare`, saved state, backgrounding, unloading, model self-test); `ModelStore` downloads and
  converts; `MacLink` talks to Ollama.
- `Lantern/Chat`: the chat screen, in UIKit. `Lantern/Views`: everything else, in SwiftUI.

## Commands

```sh
scripts/fetch-llama.sh      # pinned llama.cpp xcframework into Vendor/ (gitignored)
xcodegen generate           # after changing project.yml or adding files
cd Packages/LlamaKit && swift build -c release && .build/release/lantern-smoke ../../Models/<file>.gguf [--think] [--stop] [--state] [--lazy] [--f16]
                            # two-turn check of a GGUF on the Mac through the app's own wrapper;
                            # --state checks saved state (reopen, retry, stop, new chat) and that a
                            # restored cache answers byte for byte like the live one.
                            # Gemma runs with --lazy --f16 in the app.
.build/release/lantern-smoke <copy-of-file>.gguf --convert   # MetalConverter, in place: use a copy (cp -c)
```

In a Debug build, `simctl launch --console <device> com.merimerimeri.Lantern -selftest` tests each
downloaded model, and `-enginetest [-smart] [-convert]` drives a short chat through `Engine`.

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
- **Never rewind the KV cache on Inkling.** Its short-conv layers can't roll back state
  (`LlamaModel.canRewind` is false, from `llama_model_is_hybrid`), so its cache is only ever
  appended to, restored or cleared. `LlamaModel` appends the next turn after the model's own
  turn-end token; history passed back must be byte-identical to what was streamed. Gemma with
  thinking on re-renders instead, because its template drops old thinking.
- **Going back on Inkling means restoring, not rewinding.** Each clean turn end is saved to
  `Caches/kv/<Conversation.stateID>` (`llama_state_seq_save_file` plus the transcript it holds,
  keyed by model file, context length and KV type); Inkling also keeps the turn before, and an
  in-memory snapshot taken right after the system prompt. Reopening a chat, Retry, a message
  after Stop and a new chat start from one of those instead of reading everything again. All of
  it is in `LlamaModel.run`/`reuse`; `Engine` only passes the directory. Run
  `lantern-smoke --state` on both models after touching it.
- **The system prompt is frozen per chat** (`Conversation.systemPrompt`, set at creation, date
  included). It's the start of every cache and saved state: anything in it that changes between
  turns makes Inkling read the whole chat again.
- **Inkling's GGUFs must be converted before Metal runs all of them.** Unsloth stores some
  `ffn_down_exps` tensors as NVFP4, which Metal has no kernel for: those layers fall back to the
  CPU (Mac: prefill 50 tok/s instead of 1100, generation 18 instead of 34). `ModelStore.convert`
  runs `MetalConverter` after a download (or from Readiness), rewriting them as IQ4_NL: same
  size, about 7% relative error on those tensors. A converted file is a few bytes larger than
  the catalog's size and carries an xattr (and a GGUF key) saying so. Drop this when llama.cpp
  gains an NVFP4 Metal kernel.
- **One on-device model loaded at a time.** `Engine.load` frees the old one first. It stays
  loaded while Lantern is in front and is unloaded on a memory warning or on leaving the app,
  after its state is saved; `Engine.prepare` (called when a chat opens) loads it again.
- **Per-model settings live in `CatalogModel.options`.** Gemma: F16 KV cache (faster, 70 MB) and
  `lazy_mode` (halves cold load). Inkling: Q8_0 cache; `swa_full` is off for any model that can't
  rewind (550 MB less).
- **The system prompt is neutral.** Outages are why Lantern exists, not something the models should
  assume: no disaster or emergency framing in the prompt, starters or copy.
- **Offline first.** Nothing may need the network to launch or to open an existing chat.
- Distributed by TestFlight with a monthly rebuild, like Quill. A build stops launching 90 days after
  upload; Readiness shows the date from `LanternBuildDate`, stamped into Info.plist at build time.
