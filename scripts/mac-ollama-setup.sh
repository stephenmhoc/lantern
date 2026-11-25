#!/bin/sh
# Sets up Ollama on the Mac Studio for Lantern: Inkling (the usual model) kept loaded for good,
# the other models for 30 minutes after their last use, all at the context Lantern asks for.
# Keeping all three resident held ~60 GB of the Mac's 96 GB for good.
#
# It also advertises Ollama over Bonjour (`_ollama._tcp`, which Ollama doesn't do itself), so
# Lantern's Add a Computer list finds this Mac on the home network. The TXT record carries the
# Mac's .local name (`host=`, which survives a new IP address) and, if Tailscale is running, its
# MagicDNS name (`tailnet=`), so one tap in Lantern sets up both the home network and the tailnet.
#
#   scripts/mac-ollama-setup.sh install    # once: two login agents, `apply` at every login and
#                                          # the Bonjour advertisement, which launchd keeps running
#   scripts/mac-ollama-setup.sh apply      # now: set the variables, restart Ollama, preload
#   scripts/mac-ollama-setup.sh advertise  # in the foreground: what the second agent runs
#   scripts/mac-ollama-setup.sh uninstall  # both agents
#
# Ollama.app's server reads its environment from launchd, which `launchctl setenv` changes only
# until the next reboot: hence the login agent.
set -eu

PINNED="inkling-2-mini:latest"   # loaded at login and never unloaded (Lantern sends keep_alive -1)
KEEP_ALIVE=30m                   # everything else: unloaded after this long unused
# The same num_ctx Lantern sends (MacLink.defaultContext). A request with another context makes
# Ollama load the model again, so every client gets this one unless it asks otherwise.
CONTEXT=16384
LABEL=com.merimerimeri.lantern.ollama
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BONJOUR_LABEL=com.merimerimeri.lantern.bonjour
BONJOUR_PLIST="$HOME/Library/LaunchAgents/$BONJOUR_LABEL.plist"
SELF="$HOME/Library/Application Support/Lantern/mac-ollama-setup.sh"

apply() {
    launchctl setenv OLLAMA_KEEP_ALIVE "$KEEP_ALIVE"     # for models a request doesn't pin
    launchctl setenv OLLAMA_MAX_LOADED_MODELS 3          # room for all three while in use
    launchctl setenv OLLAMA_CONTEXT_LENGTH "$CONTEXT"
    launchctl setenv OLLAMA_HOST 0.0.0.0:11434           # reachable from the phone

    # Restart so the server picks the variables up: the app passes its own environment on to
    # `ollama serve`, so the app itself has to start again after them. It ignores a polite quit
    # (it stays in the menu bar), so stop the processes.
    pkill -x Ollama 2>/dev/null || true
    pkill -f "Ollama.app/Contents/Resources/ollama" 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -qf "Ollama.app/Contents" || break; sleep 0.5; done
    open -a Ollama
    for _ in $(seq 1 60); do curl -sf http://127.0.0.1:11434/api/version >/dev/null && break; sleep 1; done

    # Load the pinned model now (an empty chat loads without generating), not on the first question.
    for model in $PINNED; do
        curl -sf http://127.0.0.1:11434/api/chat -d "{\"model\":\"$model\",\"messages\":[],\"keep_alive\":-1,\"options\":{\"num_ctx\":$CONTEXT}}" >/dev/null \
            && echo "loaded $model" || echo "couldn't load $model"
    done
}

# The Mac's MagicDNS name ("mac-studio.tail1234.ts.net"), or nothing without Tailscale.
tailnet_name() {
    for ts in tailscale /usr/local/bin/tailscale /opt/homebrew/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
        command -v "$ts" >/dev/null 2>&1 || continue
        name=$("$ts" status --json 2>/dev/null | plutil -extract Self.DNSName raw -o - - 2>/dev/null || true)
        if [ -n "$name" ]; then echo "${name%.}"; return 0; fi
    done
    return 0
}

# Registers "<Computer Name>" as _ollama._tcp on port 11434 for as long as it runs (launchd
# starts it again if it stops). Tailscale may still be starting at login: wait for it a little.
advertise() {
    name=$(scutil --get ComputerName)
    host="$(scutil --get LocalHostName).local"
    tailnet=""
    for _ in $(seq 1 15); do
        tailnet=$(tailnet_name)
        [ -n "$tailnet" ] && break
        sleep 2
    done
    echo "advertising \"$name\" host=$host tailnet=${tailnet:-none}"
    if [ -n "$tailnet" ]; then
        exec /usr/bin/dns-sd -R "$name" _ollama._tcp local 11434 path=/api "host=$host" "tailnet=$tailnet"
    else
        exec /usr/bin/dns-sd -R "$name" _ollama._tcp local 11434 path=/api "host=$host"
    fi
}

case "${1:-apply}" in
apply) apply ;;
advertise) advertise ;;
install)
    mkdir -p "$(dirname "$SELF")" "$HOME/Library/LaunchAgents"
    cp "$0" "$SELF"
    chmod +x "$SELF"
    cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>/bin/sh</string><string>$SELF</string><string>apply</string></array>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>/tmp/$LABEL.log</string>
    <key>StandardErrorPath</key><string>/tmp/$LABEL.log</string>
</dict>
</plist>
EOF
    # The advertisement runs for good: launchd starts it at login and again if it stops.
    cat >"$BONJOUR_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$BONJOUR_LABEL</string>
    <key>ProgramArguments</key><array><string>/bin/sh</string><string>$SELF</string><string>advertise</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>StandardOutPath</key><string>/tmp/$BONJOUR_LABEL.log</string>
    <key>StandardErrorPath</key><string>/tmp/$BONJOUR_LABEL.log</string>
</dict>
</plist>
EOF
    for label in "$LABEL" "$BONJOUR_LABEL"; do
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$label.plist"   # runs now, and at every login
    done
    echo "installed $PLIST and $BONJOUR_PLIST"
    ;;
uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$BONJOUR_LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$BONJOUR_PLIST" "$SELF"
    for v in OLLAMA_KEEP_ALIVE OLLAMA_MAX_LOADED_MODELS OLLAMA_CONTEXT_LENGTH; do launchctl unsetenv "$v"; done
    echo "removed; restart Ollama to drop the settings"
    ;;
*) echo "usage: $0 [apply|install|advertise|uninstall]" >&2; exit 2 ;;
esac
