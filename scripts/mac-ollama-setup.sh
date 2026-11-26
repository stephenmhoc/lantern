#!/bin/sh
# Sets up Ollama on the Mac Studio for Lantern: the other models stay loaded for 30 minutes after
# their last use, all at one context, and Ollama listens on this Mac only. Devices reach it through
# Lantern for Mac's bridge (`lantern-bridge`, port 11443): encrypted, paired devices only. The
# bridge also keeps Inkling loaded for good (its "Keep loaded" pin) and advertises this Mac over
# Bonjour (`_lantern._tcp`). Keeping all three resident held ~60 GB of the Mac's 96 GB.
#
#   scripts/mac-ollama-setup.sh install    # once: a login agent that runs `apply` at every login
#   scripts/mac-ollama-setup.sh apply      # now: set the variables and restart Ollama
#   scripts/mac-ollama-setup.sh uninstall  # the agent
#
# Ollama.app's server reads its environment from launchd, which `launchctl setenv` changes only
# until the next reboot: hence the login agent. Installing also removes the Bonjour agent earlier
# versions of this script installed (`_ollama._tcp`, Ollama open to the network unencrypted).
set -eu

KEEP_ALIVE=30m                   # unloaded after this long unused, unless the bridge pins it
# One context for every client: a request with another makes Ollama load the model again. The
# OpenAI API the bridge serves has no num_ctx, so this is what every request gets.
CONTEXT=16384
LABEL=com.merimerimeri.lantern.ollama
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
OLD_BONJOUR_LABEL=com.merimerimeri.lantern.bonjour
SELF="$HOME/Library/Application Support/Lantern/mac-ollama-setup.sh"

apply() {
    launchctl setenv OLLAMA_KEEP_ALIVE "$KEEP_ALIVE"
    launchctl setenv OLLAMA_MAX_LOADED_MODELS 3          # room for all three while in use
    launchctl setenv OLLAMA_CONTEXT_LENGTH "$CONTEXT"
    launchctl setenv OLLAMA_HOST 127.0.0.1:11434         # this Mac only: devices go through the bridge

    # Restart so the server picks the variables up: the app passes its own environment on to
    # `ollama serve`, so the app itself has to start again after them. It ignores a polite quit
    # (it stays in the menu bar), so stop the processes.
    pkill -x Ollama 2>/dev/null || true
    pkill -f "Ollama.app/Contents/Resources/ollama" 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -qf "Ollama.app/Contents" || break; sleep 0.5; done
    # The app's own "Expose Ollama to the network" setting overrides OLLAMA_HOST: turn it off
    # while the app is stopped, since it writes its settings back.
    db="$HOME/Library/Application Support/Ollama/db.sqlite"
    if [ -f "$db" ]; then sqlite3 "$db" "update settings set expose = 0;" 2>/dev/null || true; fi
    open -a Ollama
    for _ in $(seq 1 60); do curl -sf http://127.0.0.1:11434/api/version >/dev/null && break; sleep 1; done
}

remove_old_bonjour() {
    launchctl bootout "gui/$(id -u)/$OLD_BONJOUR_LABEL" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$OLD_BONJOUR_LABEL.plist"
}

case "${1:-apply}" in
apply) apply ;;
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
    remove_old_bonjour
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"   # runs now, and at every login
    echo "installed $PLIST"
    ;;
uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    remove_old_bonjour
    rm -f "$PLIST" "$SELF"
    for v in OLLAMA_KEEP_ALIVE OLLAMA_MAX_LOADED_MODELS OLLAMA_CONTEXT_LENGTH OLLAMA_HOST; do launchctl unsetenv "$v"; done
    echo "removed; restart Ollama to drop the settings"
    ;;
*) echo "usage: $0 [apply|install|uninstall]" >&2; exit 2 ;;
esac
