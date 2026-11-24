#!/bin/sh
# Sets up Ollama on the Mac Studio for Lantern: Inkling (the usual model) kept loaded for good,
# the other models for 30 minutes after their last use, all at the context Lantern asks for.
# Keeping all three resident held ~60 GB of the Mac's 96 GB for good.
#
#   scripts/mac-ollama-setup.sh install   # once: a login agent that runs `apply` at every login
#   scripts/mac-ollama-setup.sh apply     # now: set the variables, restart Ollama, preload
#   scripts/mac-ollama-setup.sh uninstall
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
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"   # runs `apply` now, and at every login
    echo "installed $PLIST"
    ;;
uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$SELF"
    for v in OLLAMA_KEEP_ALIVE OLLAMA_MAX_LOADED_MODELS OLLAMA_CONTEXT_LENGTH; do launchctl unsetenv "$v"; done
    echo "removed; restart Ollama to drop the settings"
    ;;
*) echo "usage: $0 [apply|install|uninstall]" >&2; exit 2 ;;
esac
