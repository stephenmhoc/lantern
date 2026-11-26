#!/bin/bash
# The bridge's end-to-end check, on the Mac: a bridge of its own (temporary folder, its own port,
# no Bonjour) in front of a Splash already running, then everything a device does through it:
#
#   pair by QR code and by typed code (pinning the certificate, checking the bridge's proof),
#   a wrong code refused, an unpaired request refused, Splash's model listed with what it can do,
#   a streamed answer with thinking on and off, a tool call, an image, the drafter's numbers in
#   the status, and a Tailscale join key minted through a stand-in for Tailscale's API.
#
#   scripts/bridge-e2e.sh            against Splash at BRIDGE_E2E_UPSTREAM (http://127.0.0.1:8000)
#   scripts/bridge-e2e.sh --spawn    also let a bridge start its own Splash on a spare port, wait
#                                    for it to be ready, answer once, and stop it (needs ~20 GB)
#
# It never touches the bridge Lantern for Mac runs (port 11443 and its folder) and prints no
# tokens, keys or codes.
set -euo pipefail
cd "$(dirname "$0")/../Bridge"
UPSTREAM=${BRIDGE_E2E_UPSTREAM:-http://127.0.0.1:8000}
PORT=${BRIDGE_E2E_PORT:-11453}
TS_PORT=$((PORT + 1))
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bridge-e2e.XXXXXX")
PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

go build -o "$WORK/lantern-bridge" .
# A Python whose TLS has 1.3 (the bridge takes nothing older; Xcode's python3 has LibreSSL 2.8).
PY=
for p in python3.14 python3.13 python3.12 /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3.13 python3; do
  if command -v "$p" >/dev/null && "$p" -c 'import ssl, sys; sys.exit(not ssl.HAS_TLSv1_3)' 2>/dev/null; then PY=$p; break; fi
done
[ -n "$PY" ] || { echo "bridge e2e: needs a Python with TLS 1.3 (brew install python)"; exit 1; }
sips -s format jpeg -Z 256 /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertStopIcon.icns \
  --out "$WORK/image.jpg" >/dev/null

# A stand-in for Tailscale's API: OAuth client credentials, then a key, checked as Tailscale would.
cat >"$WORK/fake_tailscale.py" <<'EOF'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/api/v2/oauth/token":
            f = urllib.parse.parse_qs(body.decode())
            if f.get("grant_type") == ["client_credentials"] and f.get("client_id") == ["e2e-client"] and f.get("client_secret") == ["e2e-secret"]:
                return self.reply(200, {"access_token": "e2e-access", "token_type": "Bearer", "expires_in": 3600})
            return self.reply(401, {"message": "invalid client"})
        if self.path == "/api/v2/tailnet/-/keys":
            if self.headers.get("Authorization") != "Bearer e2e-access":
                return self.reply(401, {"message": "bad token"})
            req = json.loads(body)
            c = req["capabilities"]["devices"]["create"]
            ok = (c["reusable"] is False and c["ephemeral"] is False and c["preauthorized"] is True
                  and c["tags"] == ["tag:lantern"] and 0 < req["expirySeconds"] <= 3600)
            open(sys.argv[2], "w").write(json.dumps(req))
            if not ok:
                return self.reply(400, {"message": "unexpected key request"})
            return self.reply(200, {"id": "k1", "key": "tskey-auth-e2e-fake", "expires": "2030-01-01T00:00:00Z",
                                    "capabilities": req["capabilities"]})
        self.reply(404, {"message": "not found"})
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
"$PY" -I "$WORK/fake_tailscale.py" "$TS_PORT" "$WORK/key-request.json" &
PIDS+=($!)

start_bridge() { # dir port [upstream] → the bridge's pid in BRIDGE_PID
  mkdir -p "$1"
  env LANTERN_BRIDGE_DIR="$1" LANTERN_BRIDGE_PORT="$2" LANTERN_BRIDGE_BONJOUR=off \
    LANTERN_BRIDGE_UPSTREAM="${3:-}" LANTERN_TAILSCALE_API="http://127.0.0.1:$TS_PORT" \
    LANTERN_TAILNET_HOST=e2e-mac.tail0000.ts.net \
    "$WORK/lantern-bridge" serve >"$1/bridge.log" 2>&1 &
  BRIDGE_PID=$!
  PIDS+=($BRIDGE_PID)
}

start_bridge "$WORK/bridge" "$PORT" "$UPSTREAM"
cat >"$WORK/client.py" <<'EOF'
import base64, hashlib, hmac, http.client, json, os, secrets, socket, ssl, sys, time, urllib.parse

DIR, PORT, IMAGE, KEYREQ = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
ONLY_ONE_ANSWER = len(sys.argv) > 5
failures = []
def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok: failures.append(what)

class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX); self.sock.connect(os.path.join(DIR, "admin.sock"))
def admin(method, path, body=None):
    c = Unix("bridge", timeout=60)
    c.request(method, path, body=json.dumps(body) if body is not None else None)
    r = c.getresponse(); data = r.read()
    return r.status, (json.loads(data) if data.strip() else None)

def https(method, path, body=None, token=None, pin=None, stream=False):
    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    c = http.client.HTTPSConnection("127.0.0.1", PORT, context=ctx, timeout=300)
    c.connect()
    cert = c.sock.getpeercert(binary_form=True)
    if pin and hashlib.sha256(cert).hexdigest() != pin:
        raise SystemExit("the bridge's certificate isn't the pinned one")
    headers = {"Content-Type": "application/json"}
    if token: headers["Authorization"] = "Bearer " + token
    c.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
    r = c.getresponse()
    if stream: return r
    data = r.read()
    return r.status, (json.loads(data) if data.strip() else None)

# Wait for the bridge and for Splash behind it.
for _ in range(600):
    try:
        status, s = admin("GET", "/status")
        if s["splash"]["state"] == "ready": break
    except OSError: pass
    time.sleep(1)
status, s = admin("GET", "/status")
check(s["splash"]["state"] == "ready", f"Splash {s['splash'].get('version')} ready at {s['splash']['url']} (adopted={s['splash']['adopted']})")
fp = s["fingerprint"]

# Pair by QR code (no Tailscale client yet: home network only).
_, offer = admin("POST", "/pairing")
q = urllib.parse.parse_qs(urllib.parse.urlparse(offer["link"]).query)
check(q["fp"] == [fp] and q["v"] == ["1"] and q.get("addr"), "QR link carries v, fp and addresses")
code, p = https("POST", "/lantern/v1/pair", {"code": q["code"][0], "device": "E2E QR"}, pin=q["fp"][0])
check(code == 200 and p["token"] and p["tailnet"]["status"] == "not_configured", f"paired by QR code: tailnet {p['tailnet']['status']}")
qr_token = p["token"]
code, _ = https("POST", "/lantern/v1/pair", {"code": q["code"][0], "device": "again"}, pin=fp)
check(code == 403, "a QR code works once")

code, _ = https("GET", "/v1/models")
check(code == 401, "an unpaired request is refused")

# Tailscale: a wrong secret is refused, the right one kept.
code, _ = admin("PUT", "/tailscale", {"client_id": "e2e-client", "client_secret": "wrong"})
check(code == 400, "a Tailscale OAuth client Tailscale refuses isn't kept")
code, ts = admin("PUT", "/tailscale", {"client_id": "e2e-client", "client_secret": "e2e-secret"})
check(code == 200 and ts["configured"] and "client_secret" not in ts, "Tailscale OAuth client kept (secret never shown)")
check(oct(os.stat(os.path.join(DIR, "tailscale.json")).st_mode & 0o777) == "0o600", "tailscale.json is 0600")

# Pair by typed code, as the device does it (README: "Pairing with a typed code").
_, shown = admin("POST", "/pairing/code")
typed = shown["code"]
check(len(typed) == 9 and typed[4] == "-" and all(ch in "ABCDEFGHJKMNPQRSTVWXYZ23456789" for ch in typed.replace("-", "")), "a code to type, grouped ABCD-EFGH")
def key_for(code, fingerprint):
    norm = "".join(ch for ch in code.upper() if ch.isascii() and ch.isalnum())
    return hashlib.pbkdf2_hmac("sha256", norm.encode(), ("lantern-pair-code-v1:" + fingerprint.lower()).encode(), 100_000, 32)
def mac(key, msg): return hmac.new(key, msg.encode(), hashlib.sha256).hexdigest()
nonce = secrets.token_hex(32)
wrong = key_for("ABCD-EFGH" if typed != "ABCD-EFGH" else "ABCD-EFGJ", fp)
code, _ = https("POST", "/lantern/v1/pair-code", {"nonce": nonce, "proof": mac(wrong, "lantern device " + nonce), "device": "E2E typed"}, pin=fp)
check(code == 403, "a wrong code is refused")
impostor = key_for(typed, "00" * 32)  # the right code, but proved for another certificate
code, _ = https("POST", "/lantern/v1/pair-code", {"nonce": nonce, "proof": mac(impostor, "lantern device " + nonce), "device": "E2E typed"}, pin=fp)
check(code == 403, "a proof made for another certificate is refused")
key = key_for(typed.lower(), fp)  # typed in lower case: the same code
nonce = secrets.token_hex(32)
code, p = https("POST", "/lantern/v1/pair-code", {"nonce": nonce, "proof": mac(key, "lantern device " + nonce), "device": "E2E typed"}, pin=fp)
check(code == 200 and hmac.compare_digest(p["proof"], mac(key, "lantern bridge " + nonce + " " + p["token"])), "paired by typed code; the bridge's proof checks out")
t = p["tailnet"]
check(t["status"] == "ok" and t["auth_key"].startswith("tskey-auth-") and t["host"] and t["address"].endswith(f":{PORT}"), f"a Tailscale join key came with it (tags {t.get('tags')}, address on the tailnet given)")
req = json.load(open(KEYREQ))
c = req["capabilities"]["devices"]["create"]
check(c == {"reusable": False, "ephemeral": False, "preauthorized": True, "tags": ["tag:lantern"]} and req["expirySeconds"] == 900,
      f"key asked for: one-time, pre-authorized, not ephemeral, tag:lantern, {req['expirySeconds']} s")
code, _ = admin("GET", "/pairing/code")
check(code == 404, "the typed code is used up")
_, shown = admin("POST", "/pairing/code")
for i in range(5):
    n = secrets.token_hex(32)
    code, _ = https("POST", "/lantern/v1/pair-code", {"nonce": n, "proof": "00" * 32, "device": "guess"}, pin=fp)
check(code == 429 and admin("GET", "/pairing/code")[0] == 404, "five wrong tries use the code up")
token = p["token"]

# The model, as the app reads it.
code, models = https("GET", "/v1/models", token=token)
m = models["data"][0] if code == 200 and models["data"] else {}
info = m.get("lantern", {})
check(info.get("vision") and info.get("tools") and info.get("thinking"), f"/v1/models: {m.get('id')} vision, tools, thinking; efforts {info.get('reasoning_efforts')}")
model = m.get("id")

def chat(body, label):
    body = {"model": model, "stream": True, "stream_options": {"include_usage": True}, **body}
    t0 = time.time()
    r = https("POST", "/v1/chat/completions", body, token=token, stream=True)
    if r.status != 200:
        check(False, f"{label}: HTTP {r.status} {r.read()[:200]!r}"); return {}
    out = {"content": "", "reasoning": "", "calls": [], "chunks": 0, "first": None, "usage": None}
    for raw in r:
        line = raw.decode().strip()
        if not line.startswith("data: ") or line == "data: [DONE]": continue
        ch = json.loads(line[6:]); out["chunks"] += 1
        if ch.get("usage"): out["usage"] = ch["usage"]
        for choice in ch.get("choices") or []:
            d = choice.get("delta") or {}
            if (d.get("content") or d.get("reasoning_content")) and out["first"] is None: out["first"] = time.time() - t0
            out["content"] += d.get("content") or ""
            out["reasoning"] += d.get("reasoning_content") or ""
            for call in d.get("tool_calls") or []:
                if call.get("function", {}).get("name"): out["calls"].append(call["function"]["name"])
    out["seconds"] = time.time() - t0
    return out

def reasoning_tokens(o): return ((o.get("usage") or {}).get("completion_tokens_details") or {}).get("reasoning_tokens")

on = chat({"messages": [{"role": "user", "content": "What is 17 times 23? Answer briefly."}], "reasoning_effort": "high", "max_tokens": 800}, "thinking on")
check("391" in on.get("content", "") and on.get("reasoning"), f"thinking on: streamed in {on.get('chunks')} chunks, first after {on.get('first') or 0:.2f} s, {reasoning_tokens(on)} thinking tokens, answer {on.get('content','').strip()[:40]!r}")
off = chat({"messages": [{"role": "user", "content": "What is 17 times 23? Answer briefly."}], "reasoning_effort": "none", "max_tokens": 800}, "thinking off")
check("391" in off.get("content", ""), f"thinking off (\"none\", sent as minimal): {reasoning_tokens(off)} thinking tokens, answer {off.get('content','').strip()[:40]!r}")

_, s = admin("GET", "/status")
d = s["splash"].get("drafter") or {}
check(d.get("draft_n", 0) > 0, f"drafter in status: {d.get('draft_n_accepted')} of {d.get('draft_n')} accepted ({100*d.get('accept_rate',0):.0f}%), {d.get('tokens_per_step', 0):.2f} tokens per step, {d.get('tokens_per_second', 0):.0f} tokens/s")

if not ONLY_ONE_ANSWER:
    tool = {"type": "function", "function": {"name": "web_search", "description": "Search the web for current information.",
            "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "What to search for"}}, "required": ["query"]}}}
    calls = chat({"messages": [{"role": "user", "content": "Search the web for today's top news headline."}], "tools": [tool], "reasoning_effort": "low", "max_tokens": 800}, "tool call")
    check("web_search" in calls.get("calls", []), f"tool call streamed: {calls.get('calls')}")

    image = base64.b64encode(open(IMAGE, "rb").read()).decode()
    seen = chat({"messages": [{"role": "user", "content": [{"type": "text", "text": "What shape and colour is this icon? One sentence."},
                {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + image}}]}], "reasoning_effort": "low", "max_tokens": 600}, "image")
    check(bool(seen.get("content", "").strip()), f"image: {seen.get('content','').strip()[:90]!r}")

    code, _ = admin("DELETE", "/devices/" + next(x["id"] for x in admin("GET", "/status")[1]["devices"] if x["name"] == "E2E QR"))
    code, _ = https("GET", "/v1/models", token=qr_token)
    check(code == 401, "a removed device is refused")

print("bridge e2e:", "ok" if not failures else f"{len(failures)} failed")
sys.exit(1 if failures else 0)
EOF

echo "== bridge on :$PORT in front of $UPSTREAM"
"$PY" -I "$WORK/client.py" "$WORK/bridge" "$PORT" "$WORK/image.jpg" "$WORK/key-request.json" || { tail -20 "$WORK/bridge/bridge.log"; exit 1; }
kill "$BRIDGE_PID"; wait "$BRIDGE_PID" 2>/dev/null || true

if [ "${1:-}" = "--spawn" ]; then
  SPAWN_PORT=$((PORT + 2))
  SPLASH_PORT=$((PORT + 3))
  mkdir -p "$WORK/spawn"
  echo "{\"splashPort\": $SPLASH_PORT}" >"$WORK/spawn/settings.json"
  echo "== bridge on :$SPAWN_PORT starting its own Splash on :$SPLASH_PORT"
  start_bridge "$WORK/spawn" "$SPAWN_PORT"
  "$PY" -I "$WORK/client.py" "$WORK/spawn" "$SPAWN_PORT" "$WORK/image.jpg" "$WORK/key-request.json" once \
    || { tail -20 "$WORK/spawn/bridge.log" "$WORK/spawn/splash.log"; exit 1; }
  kill "$BRIDGE_PID"; wait "$BRIDGE_PID" 2>/dev/null || true
  if lsof -nP -iTCP:"$SPLASH_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "FAIL  Splash still listening on :$SPLASH_PORT after the bridge stopped"; exit 1
  fi
  echo "ok    Splash stopped with the bridge"
  grep -E "splash: (started|ready)" "$WORK/spawn/bridge.log" | sed 's/^/      /'
fi
