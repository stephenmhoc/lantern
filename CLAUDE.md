# Lantern

An assistant that keeps working in an internet or power outage. iPhone and iPad, iOS 18.1+, and the
Mac through Mac Catalyst (the same target; see The Mac). Swift 6 with MainActor default isolation, SwiftData. Lantern 2.0 is deliberately small: few features, each
finished. When in doubt, delete.

A chat is answered by one of two models:

- **This device's model** (`Mode.device`): the best Gemma 4 its memory runs, picked by
  `CatalogModel.device` and never by the user. E4B (4.2 GB) on 8 GB devices, E2B (2.6 GB) on 6 GB
  (the 12B was tried and dropped: its files are retired). Each comes with its MTP drafter (faster, same output) and vision projector,
  as one download. The model belongs to the device, not the chat: a chat stores only "this device
  or the Mac", so any device continues any chat with its own model (the chats sync through iCloud:
  `ChatStore`), and every reply records the model that wrote it (`ReplyMetrics.modelTitle`).
- **The Mac** (`Mode.mac`): Inkling 2 Mini, which Splash serves on the serving Mac, through
  Lantern's bridge (`Bridge/README.md`): home network first, tailnet second. Never call it "cloud".
  It serves one model; a chat on a model it no longer serves (from before 2.0) moves to it.
  Thinking follows the model's listed `thinking` flag ("high", or "none", which the bridge makes
  "minimal"). The bridge's 503 means Splash is starting or failed: shown as such, rechecked.
  Pairing (`MacPairing`) is by the QR code's link or by the code it shows, typed and proved to a
  Mac found by Bonjour; a pair response with `tailnet.status == "ok"` carries a one-time key the
  iPhone and iPad join with (`Tailnet.join`, TailscaleKit). A Mac has no TailscaleKit: the Tailscale app.

`Mode`'s raw values (`fast`, `smart`, `qwen`, `mac`, `apple`) are stored, so all still decode:
everything but `mac` means this device (`Mode.device` is `fast`), and `Conversation.repairModes`
moves old chats over at launch. Apple Intelligence only names chats (`ChatTitler`).

## Layout

- `Packages/LlamaKit`: the llama.cpp wrapper (`LlamaModel` with the drafter, hand-written
  `ChatTemplate`s) and the `lantern-smoke` Mac CLI. Its Qwen template and non-rewinding paths stay.
- `Lantern/Engine`: `Engine` owns the one generation (send, stop, retry, compare, `prepare`, saved
  state, leaving the app); `ModelCatalog` the three Gemmas and their options; `ModelStore` the
  download; `MacLink`/`BridgeAPI`/`MacPairing`/`Tailnet` the Mac; `WebSearcher` Tavily;
  `ChatTitler` titles.
- `Lantern/Chat`: the chat screen, in UIKit (`ChatViewController`; `ChatScreen` at its end is the
  SwiftUI wrapper with the title and `ChatBanner`). `ComposerView`, `MessageCells`, `Markdown`,
  `Attachments`, `ModelPicker` (the two models, Think First, Search the Web), `EmptyChatView`.
- `Lantern/Data`: `Conversation` (the one stored model) and `ChatStore` (its container).
- `Lantern/Compare`: `CompareView`, two answers side by side with Continue With.
- `Lantern/Views`: `RootView` (one window: sidebar column on iPad, drawer on iPhone; chats with
  search, Rename and Delete by swipe or menu), `ModelSetupView` (the welcome and the model's
  page: the only place the model is downloaded, upgraded or removed), `SettingsView` (the model, the Mac, the
  Tavily key, Instructions, the build's expiry), `PersonalizationView`, `Computers/` (Settings › Mac: the paired Mac, or pairing),
  `LanternCommands` (the iPad menu bar, `BuildExpiry`), `DebugLaunch` (launch arguments, the e2e).
- `Lantern/Mac` (Catalyst only): `MacRole`, `MacServer`, `MacSettings`, `SettingsWindow`,
  `MacWelcomeView`, `MacUpdater`. `MacSupport/` is a bundle loaded at launch for AppKit and Sparkle (`MacSupportAPI`).
- `Bridge/` (Go): runs Splash (Inkling 2 Mini + DFlash2 drafter, loopback only) and serves it to
  paired devices on :11443. `scripts/mac-bundle.sh` builds it into the Mac app with its LaunchAgent.

## Commands

```sh
scripts/fetch-llama.sh      # pinned llama.cpp xcframework into Vendor/ (gitignored)
scripts/fetch-tailscale.sh  # TailscaleKit (needs Go)
xcodegen generate           # after changing project.yml or adding files
```

The simulator needs llama.cpp's own `build-xcframework.sh` output in `Vendor/build-apple/` (the
official xcframework has no simulator slice) and runs it on the CPU: use `-model e2b` there.

There are no unit tests. Two end-to-end checks (and `scripts/bridge-e2e.sh [--spawn]` for the
bridge: pairing both ways, streaming, tools, an image and Tailscale keys against a running Splash):

```sh
# 1. The models, through the app's wrapper (Mac CLI). Greedy; prints PASS/FAIL.
cd Packages/LlamaKit && swift build -c release
.build/release/lantern-smoke <model.gguf> [load flags] [--think] [--stop] [--draft <mtp.gguf>]
.build/release/lantern-smoke <model.gguf> [load flags] --state [--retry-first]
.build/release/lantern-smoke <model.gguf> [load flags] --mmproj <mmproj.gguf> --image <file>
.build/release/lantern-smoke <model.gguf> [load flags] --search [--think]   # TAVILY_API_KEY
.build/release/lantern-smoke <model.gguf> --render    # template renders, to compare with the Jinja
# Load flags, as CatalogModel.options: `--lazy --f16`.

# 2. The app, in the booted simulator: ask, answer, retry, reopen, follow up. Prints E2E PASS/FAIL.
scripts/e2e.sh          # this device's model (E2B files cloned from Models/)
scripts/e2e.sh --mac    # the Mac, if the simulator is paired
```

Debug launch arguments (`DebugLaunch.swift`): `-model e2b|e4b`, `-seedChats`,
`-ui welcome|model|modelpage|settings|mac|personalization|sidebar|search:<text>|chat|picker|compare|comparepicker`,
`-testflight`, `-e2e [-mac]`, `-pairCode <code> [-pairAt host:port@fingerprint]`. The Mac also takes
`-role serve|client|none`, `-ui role|pair`, `-light`/`-dark` and `-snapshot <path> [-snapshotDelay s]`
(saves the windows and any sheet as PNGs, then quits). Launch the Mac app with
`open -n --stdout <log> <Lantern.app> --args …` (e.g. `-role serve -e2e -mac`), not its binary: run
from a shell, the CloudKit store's setup waits forever on RunningBoard.

The Mac release: `.github/workflows/release-mac.yml` (tags `v*`, beside the iOS `release.yml`):
Developer ID archive with the profile from `Tools/app_store_connect_signing.rb prepare-mac`,
`scripts/mac-sign.sh` (inside-out re-sign and checks), notarized with the ASC key, DMG and zip on
`v<version>`, `appcast.xml` on the `appcast` prerelease. Needs the secrets DEVELOPER_ID_CERT_BASE64,
DEVELOPER_ID_CERT_PASSWORD and SPARKLE_PRIVATE_KEY.

## The Mac

- **The same app through Mac Catalyst** with the Mac idiom: NavigationSplitView sidebar with
  `.searchable`, toolbar in the titlebar, Settings in the app menu (⌘,), the chat's title as the
  window's, Mac-sized type, hover on the answer's controls. Mac-only code is under
  `#if targetEnvironment(macCatalyst)` (Catalyst is `os(iOS)`).
- **No model of its own.** The Mac never shows or offers an on-device model (`ModelStore` does
  nothing there); every chat answers through `Mode.mac`. Old on-device replies stay as history.
- **One role, chosen on first run** (`MacRole`, `mac.role`): **serve** (Apple silicon M3+, macOS
  26.4+) registers the bridge's LaunchAgent with `SMAppService` (`MacServer`), talks to the
  bridge over `admin.sock`, and pairs the app with its own bridge on 127.0.0.1. **client** works
  like an iPhone and never installs, starts or registers the bridge, Splash or the agent; switching
  to it unregisters the agent. Settings (a window of its own, `SettingsWindow`; the Mac build allows a second scene for it)
  shows the role's sections: Splash's status, Pair a Device (QR code and typed code), paired
  devices, the Tailscale OAuth client; or the paired Mac.
- **Secrets are in the Keychain on the Mac too** (the data protection keychain, which works because
  iCloud gives the app a provisioning profile, Developer ID included). Without one (-34018) they
  fall back to 0600 files in `Secrets/`, which move into the Keychain once it works.
- **A Debug build is another app** (`com.merimerimeri.Lantern.dev`, folder `Lantern Dev`, bridge
  "Lantern Dev" on 11444, using the Splash already on :8000), so it never touches the installed
  Lantern. A Release build uses `~/Library/Application Support/Lantern` (the old Mac app's
  `Chats.store` opens as is and syncs). **2.0 replaces Lantern for Mac 1.x** in place (same
  bundle ID, folder and port): a bridge already on its port that's a `lantern-bridge` (1.x's
  child process) is stopped by the new one (`Bridge/port.go`), which keeps its certificate and
  `devices.json`, so paired devices carry on; a Mac that served carries on serving, and 1.x's
  open-at-login is undone (`MacRole.tidyOldApp`).
- **Sparkle**: Check for Updates… in the app menu, automatic checks, `LANTERN_FEED_URL` and
  `LANTERN_UPDATE_KEY` in project.yml; a Debug build has no feed and never checks.

## Rules

- **SwiftUI where it can be, UIKit for the chat.** The transcript and message box are UIKit:
  streaming into a cell without reloading it, selectable answers, following the bottom only while
  the user is there, hardware-keyboard Send and Stop.
- **Never update UI per token.** `Engine.live` (a plain `LiveReply`) collects tokens; the chat
  reads it on a ~15 Hz display link. SwiftData is written when a turn starts and ends and every ~5 s.
- **One generation at a time, owned by `Engine`.** Views never hold the task. Stop cancels it.
- **One model, no choice.** The UI never lists on-device models. `ModelStore.best` is
  `CatalogModel.device`, the only one downloaded; `ModelStore.model` is the one answering.
- **A model already here keeps answering.** If it isn't the best (an upgrade from an older
  version), the best is offered once and in Settings ("A better model is available"), never
  forced. `model` only becomes `best` when all three of its files are here at their exact size
  with a GGUF header; only then are the other sizes' and retired models' files deleted. Nothing
  is deleted in a `-model` or `-e2e` run.
- **An unpaired Mac is never selected.** `Conversation.answeringMode` is what answers: a chat
  stored as `mac` answers on this device while no Mac is paired, and the picker's Mac row then
  leads to Settings (on a Mac, always `mac`, with a banner until it can answer). Use `answeringMode`, not `mode`, to decide where a reply goes.
- **Per-model settings live in `CatalogModel`.** E2B/E4B: lazy embeddings, F16 cache.
- **llama.cpp is pinned** in `scripts/fetch-llama.sh`. Before moving the pin or touching
  `LlamaModel.run`/`reuse`, run the smoke test on each Gemma (`--state`, `--think --stop`, with
  `--draft`).
- **Chat templates are hand-written** (`ChatTemplate.swift`); check with `--render`.
- **A model that can't rewind is only appended to, restored or cleared** (`canRewind`: hybrids); history passed back must be byte-identical to what was streamed.
- **Going back means restoring.** Each clean turn end is saved to
  `Caches/kv/<Conversation.stateID>/<model id>`; reopening, Retry, a message after Stop and a new
  chat start from a saved state. All of it is in `LlamaModel`; `Engine` only passes the directory.
  Model ids name these folders, so they never change.
- **The system prompt is frozen per chat** (`Conversation.systemPrompt`, date included): it's the
  start of every cache. A question sent on a later day gets a stored `dateNote` instead.
  Personalization's instructions apply to new chats only.
- **A user turn is rendered from stored fields only** (`StoredMessage.chatMessage`): date note,
  files as `<file name="…">…</file>`, then the text; images in `ChatMessage.images`. Never derive
  it again from the date, settings or files.
- **Think First and Search the Web are per chat** (`Conversation.thinking`, `.webSearch`), set in
  the model picker; new chats start with the last choices (`ChatDefaults`). Settings holds only
  the Tavily key (Keychain). Without a key the picker's search row leads to Settings.
- **Web search** (`WebSearcher`, at most 3 per reply; a failed search never fails the reply). For
  Gemma the tool is declared in the system turn (`Engine.systemMessage`, from the chat's flag and
  the key), so flipping it makes the next reply read the chat again; the Mac is offered it per
  request. Searches are stored on the reply (`StoredMessage.searches`) and rendered back from
  those fields byte for byte, `topic` exactly as the model wrote it (`news` for anything recent).
- **Images** go through the model's projector, loaded only when a chat has one; each is encoded
  once. The Mac gets `image_url` data URLs if its model lists `vision`.
- **Leaving the app** stops an on-device reply ("Stopped when you left Lantern") and unloads the
  model after saving its state; a Mac reply gets the few seconds iOS allows. No notifications.
- **Comparing** is a second answer to the last question (`Engine.compare`): A stays, only B runs;
  both sit in the reply's `versions` with a shared `compareID`. B may be the same model with
  thinking the other way. A B with nothing to show undoes the pair.
- **The chats sync through iCloud** (`ChatStore`: SwiftData's CloudKit mirror, private database,
  `iCloud.com.merimerimeri.Lantern`, the same on iOS and the Mac). The store is each platform's
  existing one, so chats already in it upload on the first sync. CloudKit's rules hold: every
  property defaulted, no unique constraints, no relationships. Without an iCloud account it's a
  local store and Settings says so; a build without the entitlement opens it without CloudKit.
  Saved model states stay in Caches. Streaming replies sync with the ~5 s saves (accepted).
- **Stored data changes are additive** (`Conversation`, `StoredMessage`, `ReplyMetrics`: new
  properties with defaults; unused ones stay, like `pinned` and the old timings). Never name a
  stored property after an NSManagedObject key (`updated`, `deleted`…).
- **`Conversation.stateID` never changes** once set.
- **The system prompt is neutral**: no disaster framing in the prompt, starters or copy.
- **Offline first.** Nothing may need the network to launch or to open an existing chat.
- **The only `lantern://` link is `pair`** (`PairOffer`), from the Mac's QR code.
- **The amber accent takes black text** (`ProminentLabel`): white on it is about 2.3:1.
- Distributed by TestFlight with a monthly rebuild; a build stops launching 90 days after upload
  and Settings shows the date (`LanternBuildDate`, stamped at build time). CI signs the one target
  with `Lantern App Store <cert id>`, passed as `LANTERN_APP_PROFILE`; the Mac with `Lantern
  Developer ID <cert id>` (`MAC_CATALYST_APP_DIRECT`) as `LANTERN_MAC_PROFILE`. Both need the
  bundle ID's iCloud container, which the ASC API can't assign (the portal or Xcode does, once);
  a profile without it is deleted and made again. MARKETING_VERSION is 2.0.0; CI sets it from
  the tag and the build number from the run (the Mac's above the published appcast's).
