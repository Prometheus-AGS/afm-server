#!/bin/bash
# Build afm-server, install it to ~/.local/bin, and (re)load the LaunchAgent.
#   scripts/install.sh            build + install + load on port 11435
#   AFM_PORT=12000 scripts/install.sh
#   scripts/install.sh --no-agent build + install the binaries only
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${AFM_PORT:-11435}"
LABEL=local.afm-server
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

swift build -c release
mkdir -p "$HOME/.local/bin" "$HOME/Library/Logs" "$HOME/Library/LaunchAgents"
install -m 755 .build/release/afm-server "$HOME/.local/bin/afm-server"
install -m 755 scripts/afm-server-launch "$HOME/.local/bin/afm-server-launch"
echo "installed ~/.local/bin/afm-server and ~/.local/bin/afm-server-launch"

[ "${1:-}" = "--no-agent" ] && exit 0

if ! grep -qE '^export AFM_API_KEY=' "$HOME/.bash_profile" 2>/dev/null; then
  echo "note: no 'export AFM_API_KEY=...' line in ~/.bash_profile; the service will not start until you add one:" >&2
  echo "  echo \"export AFM_API_KEY=\\\"afm-\$(openssl rand -hex 32)\\\"\" >> ~/.bash_profile" >&2
fi

sed -e "s#__HOME__#$HOME#g" -e "s#__PORT__#$PORT#g" packaging/$LABEL.plist.template > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "loaded $LABEL on 127.0.0.1:$PORT (logs: ~/Library/Logs/afm-server.log)"
