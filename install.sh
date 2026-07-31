#!/usr/bin/env bash
#
# claude-bridge installer and updater.
#
#   curl -fsSL https://raw.githubusercontent.com/guitaripod/claude-bridge/master/install.sh | bash
#
# Installs into ~/.claude-bridge/src, builds it, writes a config with a generated password, and
# registers a service (systemd --user on Linux, launchd on macOS) so the bridge comes back after a
# reboot. Re-run it any time to update; --update is the same thing without touching config or
# service files, and is what the bridge runs when a client asks it to update itself.

set -euo pipefail

REPO="https://github.com/guitaripod/claude-bridge"
SRC="${BRIDGE_SRC:-$HOME/.claude-bridge/src}"
STATE_DIR="${BRIDGE_STATE_DIR:-$HOME/.claude-bridge}"
CONFIG="$STATE_DIR/config.env"
RUNNER="$STATE_DIR/run.sh"
LOG="$STATE_DIR/update.log"
STATE_FILE="$STATE_DIR/update.state.json"
LABEL="com.guitaripod.claude-bridge"
UNIT="claude-bridge.service"
MODE="install"
[ "${1:-}" = "--update" ] && MODE="update"

mkdir -p "$STATE_DIR"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

say() {
  if [ "$MODE" = "update" ]; then
    printf '%s\n' "$*" >>"$LOG"
  else
    printf '%s\n' "$*"
  fi
}

# The bridge polls this file to report progress to a client whose server is about to restart under
# it, so every phase change lands here before the work starts.
phase() {
  [ "$MODE" = "update" ] || return 0
  printf '{"phase":"%s","startedAt":"%s"%s}\n' "$1" "${STARTED_AT:-$(now)}" \
    "$( [ -n "${2:-}" ] && printf ',"finishedAt":"%s"' "$2" )" >"$STATE_FILE"
}

fail() {
  say "error: $*"
  phase failed "$(now)"
  exit 1
}

STARTED_AT="$(now)"
[ "$MODE" = "update" ] && phase running

need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required but not installed"; }

need git
if ! command -v swift >/dev/null 2>&1; then
  for candidate in "$HOME/.local/share/swiftly/bin" /usr/local/swift/usr/bin /opt/swift/usr/bin; do
    [ -x "$candidate/swift" ] && PATH="$candidate:$PATH" && export PATH && break
  done
fi
need swift

if [ "$MODE" = "install" ]; then
  command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ] ||
    say "warning: the claude CLI was not found — install it and log in before starting a session"
fi

fetch_source() {
  if [ -d "$SRC/.git" ]; then
    say "updating $SRC"
    [ -z "$(git -C "$SRC" status --porcelain)" ] ||
      fail "$SRC has uncommitted changes; commit, stash, or remove them first"
    git -C "$SRC" fetch --quiet --tags origin || fail "could not reach $REPO"
    local branch
    branch="$(git -C "$SRC" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo origin/master)"
    git -C "$SRC" merge --ff-only "$branch" >>"$LOG" 2>&1 ||
      fail "could not fast-forward to $branch"
  else
    say "cloning $REPO into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --quiet "$REPO" "$SRC" || fail "clone failed"
  fi
}

build() {
  say "building (this takes a few minutes the first time)"
  ( cd "$SRC" && swift build -c release ) >>"$LOG" 2>&1 || fail "build failed — see $LOG"
}

write_config() {
  [ -f "$CONFIG" ] && return 0
  local password
  password="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)"
  cat >"$CONFIG" <<EOF
# claude-bridge configuration. Edit, then restart the service.
export BRIDGE_PASSWORD="$password"
export BRIDGE_PORT=4098
# 0.0.0.0 so a phone on your tailnet can reach it; the password is what keeps it yours.
export BRIDGE_BIND=0.0.0.0
export BRIDGE_MODEL=sonnet
# export BRIDGE_APNS_KEY=\$HOME/.claude-bridge/AuthKey_XXXXXXXXXX.p8
# export BRIDGE_APNS_KEY_ID=XXXXXXXXXX
# export BRIDGE_APNS_TEAM_ID=XXXXXXXXXX
EOF
  chmod 600 "$CONFIG"
}

write_runner() {
  cat >"$RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="\$HOME/.local/bin:\$HOME/.local/share/swiftly/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
[ -f "$CONFIG" ] && . "$CONFIG"
export BRIDGE_SRC="$SRC"
exec "$SRC/.build/release/claude-bridge"
EOF
  chmod 755 "$RUNNER"
}

install_service_linux() {
  local dir="$HOME/.config/systemd/user"
  mkdir -p "$dir"
  if [ -f "$dir/$UNIT" ] && [ "$MODE" = "install" ] && [ -z "${BRIDGE_FORCE_SERVICE:-}" ]; then
    say "keeping the existing $UNIT"
  else
    cat >"$dir/$UNIT" <<EOF
[Unit]
Description=claude-bridge (headless Claude Code over HTTP/SSE)
After=network-online.target

[Service]
Type=simple
ExecStart=$RUNNER
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
  fi
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  systemctl --user enable --now "$UNIT" >/dev/null 2>&1 || fail "could not start $UNIT"
}

install_service_macos() {
  local plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  if [ -f "$plist" ] && [ "$MODE" = "install" ] && [ -z "${BRIDGE_FORCE_SERVICE:-}" ]; then
    say "keeping the existing $LABEL"
  else
    mkdir -p "$HOME/Library/LaunchAgents"
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$RUNNER</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$STATE_DIR/bridge.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/bridge.log</string>
</dict>
</plist>
EOF
  fi
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" >/dev/null 2>&1 ||
    fail "could not load $LABEL"
}

restart_service() {
  if [ "$(uname -s)" = "Darwin" ]; then
    if launchctl list | grep -q "$LABEL"; then
      say "restarting $LABEL"
      launchctl kickstart -k "gui/$(id -u)/$LABEL" >>"$LOG" 2>&1 || fail "restart failed"
      return 0
    fi
  elif systemctl --user is-enabled "$UNIT" >/dev/null 2>&1; then
    say "restarting $UNIT"
    systemctl --user restart "$UNIT" >>"$LOG" 2>&1 || fail "restart failed"
    return 0
  fi
  say "no service manages this bridge — start it again yourself"
}

report() {
  local address
  address="$(command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | head -1 || true)"
  [ -n "$address" ] || address="$(hostname)"
  local password
  password="$(. "$CONFIG" && printf '%s' "$BRIDGE_PASSWORD")"
  cat <<EOF

claude-bridge is running.

  Address   http://$address:4098
  Username  claude
  Password  $password

Put that address and password into Tailscode (Settings → Servers → Add), or:

  curl -u claude:$password http://$address:4098/health

Config    $CONFIG
Source    $SRC
Update    re-run this script, or tap Update in Tailscode
EOF
}

if [ "$MODE" = "update" ]; then
  fetch_source
  phase building
  build
  phase restarting
  restart_service
  say "updated to $(git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown)"
  phase succeeded "$(now)"
  exit 0
fi

fetch_source
build
write_config
write_runner
if [ "$(uname -s)" = "Darwin" ]; then
  install_service_macos
else
  install_service_linux
fi
sleep 2
report
