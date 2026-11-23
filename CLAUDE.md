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
- `Lantern/Chat`: the chat screen, in UIKit. `ChatScreen` at the bottom of `ChatViewController.swift`
  is its SwiftUI wrapper: editable title and title menu (Rename, Export as Markdown), the inspector,
  and the banner shown while another chat or a model test holds the engine. `Attachments.swift`
  reads files into `Attachment`s (PDFKit for PDFs, images downscaled to a 1024 px JPEG) and draws
  their chips; files come from the composer's paperclip menu, a drop anywhere on the chat, or paste.
  `Dictation.swift` is the composer's mic: on-device only, `SpeechAnalyzer`/`SpeechTranscriber` on
  iOS 26+, `SFSpeechRecognizer` with `requiresOnDeviceRecognition` otherwise; the button is hidden
  when neither works for the language.
- `Lantern/Views`: everything else, in SwiftUI. `RootView` is one window (sidebar with search,
  date sections, pin, rename, delete with undo); `LanternCommands` is the iPad menu bar, reaching
  the key window through `focusedSceneValue` (`SceneActions`, `ChatFocus`); `ChatList` holds the
  sidebar's grouping, the default mode for new chats and the undo snapshot; `ModelImport` copies a
  `.gguf` the user already has into Documents (Readiness's file picker and drop target).
- `Lantern/System`: the ways in from outside the app. `LanternLink` is the `lantern://` scheme
  (`new?mode=fast`, `ask?text=…&mode=`, `chat/<id>`), shared with the widgets. App Intents
  (`LanternIntents`: Ask Lantern, Open Chat and the App Shortcuts phrases; `NewChatIntent`, shared
  with the widgets for the control) all open the app and hand off to `SystemRouter`, which the key
  window's `RootView` claims; URLs arrive through `onOpenURL` and Spotlight taps through
  `onContinueUserActivity`, both in `RootView.handle`. `ChatEntity` is a chat for intents, Siri and
  Spotlight; `SpotlightIndex` indexes title plus the first lines after every store save and removes
  deleted chats, diffing against what it last indexed.
- `LanternWidgets`: the widget extension (`com.merimerimeri.Lantern.Widgets`): Ask Lantern
  (small/medium, mode buttons), a Lock Screen accessory and a Control Center control. Deep links
  and static content only; the build expiry comes from the app's Info.plist (`../../Info.plist`).
- Windows: one `WindowGroup(for: PersistentIdentifier.self)`. A plain window opens with no value;
  "Open in New Window" opens one with a chat's identifier. Each window restores its own selection
  with `@SceneStorage`; all share the app's one `Engine`, so a second chat can't send while one
  answers anywhere (`BusyBanner` says so).

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
downloaded model, `-enginetest [-smart] [-convert]` drives a short chat through `Engine`, and
`-featuretest [-smart] [-image <path>]` checks that a date note, an attached file and an image keep
the cache append-only (the follow-up must reuse everything; in-memory store, no chats touched).
`lantern-smoke <gemma>.gguf --lazy --f16 --mmproj <mmproj>.gguf --image <file>` checks images on
the Mac: the image is encoded once and reused by the follow-up and a retry.

The official xcframework has no simulator slice. For the simulator, build llama.cpp's
`build-xcframework.sh` at the pinned tag (needs CMake) into `Vendor/build-apple/`; in the
simulator llama.cpp runs on the CPU, since the simulator's Metal driver can't map its buffers.
Debug builds take launch arguments for checking the UI without tapping (`DebugLaunch.swift`):
`-seedChats`, `-ui readiness|settings|inspector|search:<text>|delete|newchat|sidebar|next|window`,
`-testflight` (show the expiry and reminders), `-importModel <path>`, and `-selftest`.
For the system integration: `-openURL <lantern://…>` (the app opens the link through the system
itself; `simctl openurl` stops at an "Open in Lantern?" prompt that needs a tap),
`-intent ask:<text>|new:<mode>|open:<title>` (runs that intent's `perform()`) and
`-spotlightQuery <text>` (searches Lantern's own Spotlight items after indexing).

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
  turns makes Inkling read the whole chat again. When a question is sent on a later day than the
  model last heard (the prompt's date or the last note), `Engine.send` stores a `dateNote`
  ("(Today is …)") on that message, which goes before its text.
- **A user turn is rendered from stored fields only** (`StoredMessage.chatMessage`): date note,
  then each text file as `<file name="…">…</file>`, then the typed text, joined by blank lines;
  images go in `ChatMessage.images`. Never derive any of it from the current date, settings or
  file contents at send time again: history passed back must be byte-identical.
- **Images**: Fast sees them through Gemma's vision projector (`CatalogModel.gemmaVision`, an
  optional extra in Readiness, ~1 GB, loaded beside Gemma only when a chat has an image;
  `LlamaModel.loadVision`). A prompt with images is tokenized by mtmd and always rendered in full;
  each image position gets a stand-in token from its bytes, so the shared prefix is reused and an
  image is encoded once. Only models that can rewind have a projector here. Smart can't see images
  (the turn is sent without them). Mac sends them in Ollama's `images` if `/api/show` lists
  `vision` for the model, else fails a question about an image with `MacError.noVision`.
- **Leaving the app mid-reply (iOS 26+)**: `Engine` submits a `BGContinuedProcessingTaskRequest`
  (`com.merimerimeri.Lantern.reply.<uuid>`, registered just before, strategy `.fail`) as a reply
  starts: always for Mac, for on-device only if `BGTaskScheduler.supportedResources` has `.gpu`
  (needs the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement, not yet
  added) or in the simulator (CPU). Progress is pieces against an estimate; expiry stops and saves.
  Without a started task it's the old behaviour: on-device stops ("Stopped when you left
  Lantern"), Mac gets the usual few seconds. A reply that finishes in the background posts a
  local notification (provisional authorization, never a prompt).
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
- **Conversation changes are additive** (new stored properties with defaults, like `pinned`), so
  SwiftData migrates existing chats without a schema version. The same goes for `StoredMessage`
  and `ChatMessage` (optional `attachments`, `dateNote`, `images`), which are also in saved states.
- **A chat's outside identity is `Conversation.stateID`** (`externalID`): deep links, Spotlight
  items and `ChatEntity` all use it, so it must never change once set.
- **No App Group.** It would have to be registered in the developer portal by hand. The widgets only
  deep-link; there is no share extension, because one can't open the app without an unsupported
  responder-chain trick. From the share sheet, a user's own Shortcut ("Show in Share Sheet",
  Shortcut Input → Ask Lantern) does it.
- **Menu bar shortcuts are idempotent.** ⌘1–3 and ⌘. exist both in `LanternCommands` and as
  `UIKeyCommand`s on `ChatViewController`; whichever UIKit routes the key to, it sets the same mode
  or cancels the same task.
- Distributed by TestFlight with a monthly rebuild, like Quill. A build stops launching 90 days after
  upload; Readiness shows the date from `LanternBuildDate`, stamped into Info.plist at build time,
  and offers local reminders 14 and 3 days before (permission is asked from that button, never at
  launch).
- **CI signs two targets.** `Tools/app_store_connect_signing.rb prepare` finds or creates an App Store
  profile per bundle ID, named after the certificate: `Lantern App Store <cert id>` for
  `com.merimerimeri.Lantern` and `Lantern Widgets App Store <cert id>` for
  `com.merimerimeri.Lantern.Widgets`. The archive passes their names as `LANTERN_APP_PROFILE` and
  `LANTERN_WIDGETS_PROFILE`, which each target's `PROVISIONING_PROFILE_SPECIFIER` reads (empty
  locally, where signing is automatic). Never pass `PROVISIONING_PROFILE_SPECIFIER` itself: it would
  apply to both targets. A new extension needs the same: bundle ID, profile, specifier variable and
  an ExportOptions entry.
