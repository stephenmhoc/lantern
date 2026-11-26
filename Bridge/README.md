# lantern-bridge

Connects Lantern on an iPhone or iPad to the model on the serving Mac. The bridge starts Splash
(`splash serve`, Inkling 2 Mini with its DFlash2 drafter, on 127.0.0.1 only), keeps it running and
stops it with itself, and serves it to paired devices as the OpenAI API on port 11443: TLS 1.3 with
its own self-signed certificate, which devices pin by SHA-256, and a token per device.

```sh
go build -o lantern-bridge .
lantern-bridge serve              # Splash starts with it (needs Splash 1.7.3+: brew upgrade splash)
lantern-bridge pair               # QR code in the terminal
lantern-bridge pair --code        # a code to type on the device instead
lantern-bridge status             # Splash, the drafter, the tailnet, devices
lantern-bridge tailscale set <id> # a Tailscale OAuth client (secret on stdin)
../scripts/bridge-e2e.sh [--spawn] # end to end against a running Splash
```

Its folder is `~/Library/Application Support/Lantern/Bridge` (`LANTERN_BRIDGE_DIR`): `cert.pem`,
`key.pem`, `devices.json` (token hashes), `settings.json` (`name`, `port`, `splashPort`),
`tailscale.json` (the OAuth client, 0600), `admin.sock`, `splash.log`, `splash.pid`.

`serve` takes its port before anything else. Another `lantern-bridge` on it (Lantern for Mac 1.x
ran one as the app's child, which outlives the app; an update leaves the old binary running) is
stopped with SIGTERM and the port tried again for 8 s; anything else on it is an error naming it.
1.x's folder is the same and its `cert.pem`, `key.pem` and `devices.json` read as they are, so
devices paired with it carry on (its `settings.json` keys are ignored).

For development: `LANTERN_BRIDGE_PORT` sets the port, `LANTERN_BRIDGE_UPSTREAM=http://127.0.0.1:8000`
uses a Splash already running instead of starting one, `LANTERN_BRIDGE_BONJOUR=off` doesn't
advertise, `LANTERN_TAILSCALE_API` points at a stand-in for Tailscale's API, and
`LANTERN_TAILNET_HOST` stands in for the Mac's MagicDNS name.

## Splash

The launch arguments live in one place, `splashArgs` in `splash.go`:

```
splash serve --model unsloth/Inkling-2-Mini-GGUF:UD-Q4_K_M --draft-model incoai/Inkling-2-Mini-DFlash2
             --host 127.0.0.1 --port 11480 --idle-release off --no-webui
```

`splash` (`brew install incoai/tap/splash`) is looked for on the PATH, then in `/opt/homebrew/bin`
and `/usr/local/bin`; older than 1.7.3 it isn't started and the status says "Update Splash: brew
upgrade splash". The bridge waits for `/ready`, and restarts Splash when it exits: after 2 s, doubling to 5 minutes; when Splash
gives up (exit 69) straight to 5 minutes, with its `error:` line as the status message.
`POST /splash/restart` (admin) tries again now. A Splash left running by a bridge that crashed
(`splash.pid`) is stopped before a new one starts. Splash refuses to start while another Splash
serves the same port, so the bridge has its own (11480).

## Device API (HTTPS, port 11443)

Everything but pairing needs `Authorization: Bearer <token>`.

| | |
|---|---|
| `POST /lantern/v1/pair` | `{code, device}`: the QR code's one-time code → pair response |
| `POST /lantern/v1/pair-code` | `{nonce, proof, device}`: a typed code, proved → pair response |
| `GET /lantern/v1/info` | `{name, version, backends: [{id: "splash", name: "Splash"}], splash: {state, message, version}}` |
| `GET /v1/models` | Splash's model (below); 503 with a message while Splash isn't ready |
| `POST /v1/chat/completions` | passed to Splash, streamed back event by event; 503 while it isn't ready |

`/v1/models` lists each model as

```json
{"id": "unsloth/Inkling-2-Mini-GGUF:UD-Q4_K_M", "object": "model", "owned_by": "splash",
 "lantern": {"backend": "splash", "backend_name": "Splash", "name": "unsloth/Inkling-2-Mini-GGUF:UD-Q4_K_M",
             "vision": true, "tools": true, "thinking": true, "context_length": 1010000,
             "reasoning_efforts": ["minimal", "low", "medium", "high", "xhigh"],
             "default_reasoning_effort": "high"}}
```

Chat completions go to Splash as sent, except `"reasoning_effort": "none"`, which becomes
`minimal`: Splash takes `none`, but Inkling thinks anyway, and longer than at `minimal`. Splash
streams `delta.reasoning_content`, standard `delta.tool_calls`, `timings` (with `draft_n` and
`draft_n_accepted`) on the last choice chunk and `usage` plus `metrics` on the one after.
Images go as `image_url` data URLs.

### The pair response

Both ways of pairing answer 200 with

```json
{"device_id": "…", "token": "…", "name": "Mac Studio",
 "proof": "…hex…",                          // typed code only
 "addresses": ["mac-studio.local:11443", "mac-studio.tail1234.ts.net:11443", "192.168.1.20:11443"],
 "tailnet": {"status": "ok",                // or "not_configured" or "failed", with "message"
             "auth_key": "tskey-auth-…", "expires": "2026-11-26T10:00:00Z", "tags": ["tag:lantern"],
             "host": "mac-studio.tail1234.ts.net", "ips": ["100.64.0.1"],
             "address": "mac-studio.tail1234.ts.net:11443"}}
```

A QR code's wrong or used code is 403. A tailnet failure never fails the pairing: the status
says why and the device works on the home network only.

### Pairing with a typed code

The Mac shows a code like `K7QM-3XPA`: 8 characters from `ABCDEFGHJKMNPQRSTVWXYZ23456789`, good
for one device, 10 minutes and 5 wrong tries. The code can't carry the certificate's fingerprint
or the address, so the device finds the Mac by Bonjour and proves the code without sending it:

1. Browse `_lantern._tcp` on the local network. Each bridge's TXT record has `v=1` and
   `fp=<hex SHA-256 of its certificate's DER>`. Resolve the service to host and port.
2. Normalize what the user typed: upper case, keep only `A–Z` and `0–9` (`k7qm-3xpa` → `K7QM3XPA`).
3. `key = PBKDF2-HMAC-SHA256(password: normalized code (UTF-8), salt: "lantern-pair-code-v1:" + fp
   (lower-case hex), iterations: 100000, length: 32 bytes)` (`CCKeyDerivationPBKDF` on iOS).
4. `nonce` = 32 random bytes as 64 lower-case hex characters.
   `proof = hex(HMAC-SHA256(key, "lantern device " + nonce))`, lower case.
5. Over TLS that trusts only a certificate whose SHA-256 is `fp` (as the QR flow pins),
   `POST https://<host>:<port>/lantern/v1/pair-code` with
   `{"nonce": "<nonce>", "proof": "<proof>", "device": "<device name>"}`.
6. On 200, check `response.proof == hex(HMAC-SHA256(key, "lantern bridge " + nonce + " " + token))`
   (constant-time). Only if it matches keep `fp` as the pin and `token` as the device's token;
   otherwise throw the token away: that wasn't the Mac showing the code.
   - 403: wrong code (or none showing, or another certificate): with several bridges found, try
     the next; else ask the user to check the code.
   - 429: too many wrong tries; the code is gone and the Mac must show a new one.

Why it holds: the key depends on the code and on the fingerprint the device pinned. A spoofed
Bonjour advert with another certificate gets a proof for its own fingerprint, which the real Mac
refuses and which can't be turned into the code in 10 minutes (100 000 PBKDF2 rounds per guess,
30⁸ codes); and only something that knows the code can produce the bridge's proof.

### Joining the tailnet

With `tailnet.status == "ok"` the device joins the Mac's tailnet itself (TailscaleKit) with
`auth_key` before `expires` (15 minutes; one use, pre-authorized, not ephemeral, tagged
`tag:lantern`), then reaches the bridge at `tailnet.address` with the same pin and token. The key is
minted from the Mac's OAuth client: client credentials at `POST /api/v2/oauth/token`, then
`POST /api/v2/tailnet/-/keys` with
`{"capabilities": {"devices": {"create": {"reusable": false, "ephemeral": false, "preauthorized": true, "tags": ["tag:lantern"]}}}, "expirySeconds": 900, "description": "Lantern <device>"}`.
The client needs the `auth_keys` scope and `tag:lantern` among its tags (the tailnet's policy must
define `tag:lantern` and let it reach the Mac on port 11443).

## Admin API (`admin.sock`, this user only)

| | |
|---|---|
| `GET /status` | `name, version, port, fingerprint, addresses, splash, models, devices, tailscale, pairing_code_expires` |
| `POST /pairing` | a QR code's link → `{link, expires}` |
| `POST /pairing/code` | a new code to type, replacing any → `{code: "ABCD-EFGH", expires}` |
| `GET /pairing/code` | the code showing now → `{code, expires}`, or 404 |
| `DELETE /pairing/code` | stop showing it |
| `GET /tailscale` | `{configured, client_id, tag, last_error, last_minted, host, ips}` (never the secret) |
| `PUT /tailscale` | `{client_id, client_secret}`: checked by getting a token, then kept; 400 with the reason |
| `DELETE /tailscale` | forget the client |
| `POST /splash/restart` | try starting Splash again now |
| `DELETE /devices/{id}`, `POST /devices/{id}/name`, `PUT /name` | as before |

`status.splash` is `{state: "starting"|"ready"|"failed", message, version, url, model, adopted,
restarts, since, drafter}`, and `drafter` (after a reply) is `{draft_n, draft_n_accepted,
accept_rate, cycles, tokens_per_step, tokens_per_second, at}`: tokens per step is
(accepted + cycles) / cycles from `metrics.speculation`.
