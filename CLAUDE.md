# Lantern

An LLM that keeps working in an internet or power outage. iPhone and iPad, iOS 18.1+, Swift 6 with
MainActor default isolation, SwiftData. Five modes behind one chat:

- **Gemma 4 E2B** (`Mode.fast`): on device, 2.6 GB, for 6 GB devices.
- **Gemma 4 E4B** (`Mode.smart`): on device, 4.2 GB, for 8 GB devices. Both use `lazy_mode`, so
  their per-layer embedding tables (most of the file) are read row by row from the mmapped file.
  Each drafts with its MTP head (`mtp-gemma-4-*-it.gguf`, ~60 MB, `CatalogModel.drafter`), downloaded
  with it and fetched quietly for a Gemma already here: 30–80% faster replies, same greedy output.
- **Qwen 3.5 4B** (`Mode.qwen`): on device, 2.9 GB (`Qwen3.5-4B-UD-Q4_K_XL`), for 8 GB devices. A
  hybrid (Gated DeltaNet): its cache is append-only. No drafter, no images. Sampling follows
  thinking (`Sampling.qwen35(thinking:)`, presence penalty 1.5).
- **Apple Intelligence** (`Mode.apple`): the system's Foundation Models model (iOS 26+,
  `Lantern/Engine/AppleModel.swift`). One `LanguageModelSession` per chat, rebuilt from stored history
  when it differs; no thinking; images on iOS 27. Its status (`AppleStatus`) replaces a download.
  Siri/App Intents call it "Built-in Model" (Apple trademarks are rejected there, ITMS-90626).
- **Your computers** (`Mode.mac`): every model Ollama has on the Mac Studio (Inkling 2 Mini, Gemma 4 31B,
  Muse Glimmer), home network first (works with the internet down), tailnet second. A chat keeps
  its model in `Conversation.macModel` (fixed by its first reply); the picker lists each by
  `MacLink.displayName` under "On Your <computer name>" with `desktopcomputer`, on-device ones with
  a chip. Never call them "cloud". One computer for now (`mac.lan`, `mac.tailnet`, `mac.name`).

The `Mode` raw values (`fast`, `smart`, `qwen`, `mac`, `apple`) are stored in chats and used by links,
widgets and intents, so they never change; `smart` was Inkling on device until it was dropped as too
big and slow for a phone (old chats in it now open with E4B; the Models page offers to delete the old
files). Shortcuts: ⌘1 E2B, ⌘2 E4B, ⌘3 Qwen, ⌘4 computers, ⌘5 Apple (from `Mode.allCases`).

## Layout

- `Packages/LlamaKit`: the llama.cpp wrapper (`LlamaModel` with the MTP drafter, hand-written
  `ChatTemplate`s for `gemma4` and `qwen35`) and the `lantern-smoke` Mac CLI.
- `Lantern/Engine`: `Engine` owns the one generation that can run at a time (send, stop, retry,
  `prepare`, saved state, backgrounding, unloading, model self-test); `ModelStore` downloads;
  `MacLink` talks to Ollama.
- `Lantern/Chat`: the chat screen, in UIKit. `ChatScreen` at the bottom of `ChatViewController.swift`
  is its SwiftUI wrapper: editable title and title menu (Rename, Export as Markdown), the inspector,
  and the banner shown while another chat or a model test holds the engine. `Attachments.swift`
  reads files into `Attachment`s (PDFKit for PDFs, images downscaled to a 1024 px JPEG) and draws
  their chips; files come from the composer's paperclip menu, a drop anywhere on the chat, or paste.
  `Dictation.swift` is the composer's mic: on-device only, `SpeechAnalyzer`/`SpeechTranscriber` on
  iOS 26+, `SFSpeechRecognizer` with `requiresOnDeviceRecognition` otherwise; the button is hidden
  when neither works for the language.
- `Lantern/Views`: everything else, in SwiftUI. `RootView` is one window that opens on a new chat (keyboard down, rotating
  prompt ideas from `Starter.all` in `EmptyChatView`), with past chats and Settings in a side
  panel: a sidebar column on iPad (with the inspector as a third column), a drawer sliding over the
  chat on iPhone (top-left button or edge swipe). The panel is custom (no navigation bar): Lantern and a
  search field at the top, plain rows (title on two lines, model and time) with the open chat
  highlighted, pin, rename and immediate delete (no undo, no in-app toasts) by swipe (`SwipeRow`: round buttons inside the row, not the list's swipe actions; never a full swipe) or the context menu; it lists only chats
  with messages. A chat's title starts as its first question; after an answer `ChatTitler` asks
  Apple Intelligence (when on) for a few words, and only ever replaces a title still equal to the
  question, so a rename sticks; deleting the chat on screen goes to a new chat. Only a window opened for a chat
  restores its selection;
  `LanternCommands` is the iPad menu bar, reaching the key window through `focusedSceneValue`
  (`SceneActions`, `ChatFocus`); `ChatList` holds the sidebar's grouping and the default mode for new
  chats; `ModelImport` copies a `.gguf` the user already has into Documents (the Models page's file
  picker and drop target). Settings has "On This iPhone" (the Models page: `ReadinessView`, pushed as
  `SettingsPage.readiness`; rows in `ModelRows.swift`, details behind a tap) and "On Your Computers"
  (`Views/Computers/`: `ComputersView`, the Add a Computer sheet finding Ollama by Bonjour
  `_ollama._tcp`, tailnet peers and a typed address). The Models page just lists models: no
  "ready"/"offline" summary. The sidebar's bottom bar has Settings on the left (badged only when no
  model can answer or the build expires soon, `Readiness.needsAttention`) and New chat on the right.
  The composer collapses to one row (model, field, mic or Stop) while the keyboard is down; its
  model button opens `ModelPicker` (a sheet on iPhone, a popover on iPad: a Think First switch, since
  `Thinking.low` and `.high` do the same, then every model), not a UIMenu; a tap
  on the transcript puts the keyboard away. Settings' "Speed and Tokens" (`ReplyDetails`) trims
  the line under each answer to only stop and cut-off notes.
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
cd Packages/LlamaKit && swift build -c release && .build/release/lantern-smoke ../../Models/<file>.gguf [--think] [--stop] [--state] [--lazy] [--f16] [--draft <mtp>.gguf]
                            # two-turn check of a GGUF on the Mac through the app's own wrapper;
                            # --state checks saved state (reopen, retry, stop, new chat) and that a
                            # restored cache answers byte for byte like the live one.
                            # Gemma runs with --lazy --f16 --draft in the app; Qwen with --qwen-sampling.
                            # --render compares a template with the GGUF's Jinja; --bench times prompt
                            # reading and generation.
```

In a Debug build, `simctl launch --console <device> com.merimerimeri.Lantern -selftest` tests each
downloaded model, `-enginetest [-smart|-qwen|-apple]` drives a short chat through `Engine`, and
`-featuretest [-smart] [-image <path>]` checks that a date note, an attached file and an image keep
the cache append-only (the follow-up must reuse everything; in-memory store, no chats touched).
`lantern-smoke <gemma>.gguf --lazy --f16 --mmproj <mmproj>.gguf --image <file>` checks images on
the Mac: the image is encoded once and reused by the follow-up and a retry.

The official xcframework has no simulator slice. For the simulator, build llama.cpp's
`build-xcframework.sh` at the pinned tag (needs CMake) into `Vendor/build-apple/`; in the
simulator llama.cpp runs on the CPU, since the simulator's Metal driver can't map its buffers.
Debug builds take launch arguments for checking the UI without tapping (`DebugLaunch.swift`):
`-seedChats`, `-ui readiness|settings|inspector|search:<text>|delete|newchat|sidebar|swipe|swipepin|next|window`,
`-testflight` (show the expiry and reminders), `-importModel <path>`, `-markdownSample full|partial`
(every answer shows a Markdown sample, `partial` cut off mid code fence), and `-selftest`.
For the system integration: `-openURL <lantern://…>` (the app opens the link through the system
itself; `simctl openurl` stops at an "Open in Lantern?" prompt that needs a tap),
`-intent ask:<text>|new:<mode>|open:<title>` (runs that intent's `perform()`) and
`-spotlightQuery <text>` (searches Lantern's own Spotlight items after indexing).

`scripts/mac-ollama-setup.sh install` (run on the Mac Studio) installs a login agent that gives
Ollama.app `OLLAMA_KEEP_ALIVE=30m`, `OLLAMA_MAX_LOADED_MODELS=3` and `OLLAMA_CONTEXT_LENGTH=16384`
(the app only passes launchd's environment to `ollama serve` when it starts after it, and ignores a
polite quit, so the script kills and reopens it) and preloads Inkling, the one model kept for good. A second agent advertises Ollama over Bonjour
(`dns-sd -R … _ollama._tcp`, TXT `host=` and `tailnet=`) so Add a Computer finds it.

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
- **llama.cpp is pinned** in `scripts/fetch-llama.sh`. Run the smoke test on both Gemmas (with
  `--think`, `--stop`, `--state` and `--draft`) and on Qwen (`--think --state`) before moving the pin.
- **Chat templates are hand-written** in `ChatTemplate.swift` because llama.cpp's C helper has no
  Jinja. Check them against `lantern-smoke <file> --template` when adding a model.
- **Never rewind the KV cache of a hybrid model** (Qwen 3.5; `canRewind` from
  `llama_model_is_hybrid`): its cache is only ever appended to, restored or cleared, and history
  passed back must be byte-identical to what was streamed. Its replies stay in the cache as streamed,
  thinking included, even though its template drops old thinking. Gemma rewinds; with thinking on it
  re-renders. Only a model that can rewind gets an MTP drafter: rejected drafts are removed with
  `llama_memory_seq_rm`.
- **Going back means restoring.** Each clean turn end is saved to
  `Caches/kv/<Conversation.stateID>/<model id>` (each model its own, so a comparison or Retry With
  never overwrites another's; states from before sat in the chat's folder and are moved by
  `LlamaModel.adoptLegacyState`) (`llama_state_seq_save_file` plus the transcript it holds,
  keyed by model file, context length and KV type); a model that can't rewind also keeps the turn
  before, and an in-memory snapshot taken right after the system prompt. Reopening a chat, Retry, a message
  after Stop and a new chat start from one of those instead of reading everything again. All of
  it is in `LlamaModel.run`/`reuse`; `Engine` only passes the directory. Run
  `lantern-smoke --state` on both Gemmas after touching it.
- **The system prompt is frozen per chat** (`Conversation.systemPrompt`, set at creation, date
  included). It's the start of every cache and saved state: anything in it that changes between
  turns makes the model read the whole chat again. When a question is sent on a later day than the
  model last heard (the prompt's date or the last note), `Engine.send` stores a `dateNote`
  ("(Today is …)") on that message, which goes before its text.
- **A user turn is rendered from stored fields only** (`StoredMessage.chatMessage`): date note,
  then each text file as `<file name="…">…</file>`, then the typed text, joined by blank lines;
  images go in `ChatMessage.images`. Never derive any of it from the current date, settings or
  file contents at send time again: history passed back must be byte-identical.
- **Images**: each Gemma sees them through its own vision projector (`CatalogModel.gemmaVision`,
  `gemmaE4BVision`: optional extras on each Gemma's Models detail page, ~1 GB, loaded beside it only when a chat has an image;
  `LlamaModel.loadVision`). A prompt with images is tokenized by mtmd and always rendered in full;
  each image position gets a stand-in token from its bytes, so the shared prefix is reused and an
  image is encoded once. Only models that can rewind have a projector here. Mac sends them in Ollama's `images` if `/api/show` lists
  `vision` for the model, else fails a question about an image with `MacError.noVision`.
- **Leaving the app mid-reply (iOS 26+)**: `Engine` submits a `BGContinuedProcessingTaskRequest`
  (`com.merimerimeri.Lantern.reply.<uuid>`, registered just before, strategy `.fail`) as a reply
  starts: always for Mac, for on-device only if `BGTaskScheduler.supportedResources` has `.gpu`
  (needs the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement, not yet
  added) or in the simulator (CPU). Progress is pieces against an estimate; expiry stops and saves.
  Without a started task it's the old behaviour: on-device stops ("Stopped when you left
  Lantern"), Mac gets the usual few seconds. A reply that finishes in the background posts a
  local notification (provisional authorization, never a prompt).
- **Mac latency.** Requests for Inkling carry `keep_alive: -1` (a request's value overrides the
  server's; Ollama's 5-minute default meant reloading the model for most questions); the other Mac
  models send none, so the server's 30 minutes applies (all three resident held ~60 GB), and `Engine.prepare` calls
  `MacLink.warm()` (an empty `/api/chat` with the same `num_ctx`, which loads the model) when a Mac
  chat opens or typing starts. `resolve()` races the home network and the tailnet; a network change
  (`NWPathMonitor`) marks the route stale so a send re-checks instead of hanging on a dead route.
  The tailnet probe races Lantern's own node against the Tailscale app's VPN and the route
  remembers which answered. The footnote breaks down the wait (found the Mac, connected, loaded,
  read the chat; `MacLink.Timings`). Keep `num_ctx` the same on every request: a different one
  makes Ollama reload the model. Inkling thinks even with `think: false` (Ollama just hides it,
  so nothing showed for seconds); `MacLink.alwaysThinks` models are always asked for thinking.
- **One on-device model loaded at a time.** `Engine.load` frees the old one first. It stays
  loaded while Lantern is in front and is unloaded on a memory warning or on leaving the app,
  after its state is saved; `Engine.prepare` (called when a chat opens) loads it again.
- **Per-model settings live in `CatalogModel.options`.** Gemma: F16 KV cache (faster, small),
  `lazy_mode` (halves cold load) and its drafter. Batch 1024 for all, cheap because logits outputs are
  capped (`n_outputs_max`). `swa_full` is off for any model that can't rewind.
- **Apple Intelligence runs out of process.** On devices under 7 GB the loaded llama model is saved
  and unloaded before an Apple request. In the background it's treated like the Mac (no GPU needed).
  A chat too long for its context fails with `.contextFull` like the others (or trims when asked).
- **The system prompt is neutral.** Outages are why Lantern exists, not something the models should
  assume: no disaster or emergency framing in the prompt, starters or copy.
- **Offline first.** Nothing may need the network to launch or to open an existing chat.
- **Conversation changes are additive** (new stored properties with defaults, like `pinned`), so
  SwiftData migrates existing chats without a schema version. The same goes for `StoredMessage`
  and `ChatMessage` (optional `attachments`, `dateNote`, `images`), which are also in saved states.
- **Never name a stored property after an NSManagedObject key** (`updated`, `deleted`, `inserted`,
  `faulted`…). SwiftData sits on Core Data, which read `Conversation.updated` as `isUpdated`, so
  every save stored 0. `lastActive` replaced it (`Conversation.repairActivity` fills old chats).
- **A chat's outside identity is `Conversation.stateID`** (`externalID`): deep links, Spotlight
  items and `ChatEntity` all use it, so it must never change once set.
- **No App Group.** It would have to be registered in the developer portal by hand. The widgets only
  deep-link; there is no share extension, because one can't open the app without an unsupported
  responder-chain trick. From the share sheet, a user's own Shortcut ("Show in Share Sheet",
  Shortcut Input → Ask Lantern) does it.
- **Menu bar shortcuts are idempotent.** ⌘1–5 and ⌘. exist both in `LanternCommands` and as
  `UIKeyCommand`s on `ChatViewController`; whichever UIKit routes the key to, it sets the same mode
  or cancels the same task.
- Distributed by TestFlight with a monthly rebuild, like Quill. A build stops launching 90 days after
  upload; the Models page shows the date from `LanternBuildDate`, stamped into Info.plist at build time,
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
- **Comparing two models** is a second answer to the last question, not a mode: the answer menu's
  "Compare With" (`Engine.compare`) keeps the current answer as A and runs only B; both sit in the
  reply's `versions` with a shared `ReplyMetrics.compareID` (`StoredMessage.comparison`). A B that
  fails or is stopped before any text shows A again and undoes the pair. The footer's Compare
  button opens `CompareView` (`Lantern/Compare`, a sheet of `ChatScreen`: columns on iPad, A | B on
  iPhone, the metrics table, Prefer and Continue With). Only speed and the time to answer after
  reading (first answer word less reading, finding the Mac and connecting) are ranked; load,
  reading, first token and answer time depend on memory, the network or the answer's length.
  B may be A's own model with thinking the other way:
  Compare With opens `ComparePicker` (the model picker with a Think First switch for B), and
  `ReplyMetrics.labeledTitle` adds "· Thinking" to tell the sides apart; Continue With takes the
  answer's thinking too. `-ui compare[:b][:metrics]` seeds and shows one, `-ui compare:picker` the picker.
