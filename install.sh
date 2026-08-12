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
#
# A client app that already minted a password can pass it through the pipe:
#
#   curl -fsSL https://raw.githubusercontent.com/guitaripod/claude-bridge/master/install.sh | BRIDGE_PASSWORD=xxx bash

set -euo pipefail

REPO="https://github.com/guitaripod/claude-bridge"
SRC="${BRIDGE_SRC:-$HOME/.claude-bridge/src}"
STATE_DIR="${BRIDGE_STATE_DIR:-$HOME/.claude-bridge}"
CONFIG="$STATE_DIR/config.env"
RUNNER="$STATE_DIR/run.sh"
LOG="$STATE_DIR/update.log"
STATE_FILE="$STATE_DIR/update.state.json"
LABEL="${BRIDGE_LABEL:-com.guitaripod.claude-bridge}"
UNIT="${BRIDGE_UNIT:-claude-bridge.service}"
PORT="${BRIDGE_PORT:-4098}"
MODE="install"
MANAGED=""
for argument in "$@"; do
  case "$argument" in
    --update) MODE="update" ;;
    # The bridge started this update and will restart itself once the build lands, so the script
    # must not touch the service: it is a child of the very thing it would be restarting.
    --managed) MANAGED="1" ;;
  esac
done

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
# it, so every phase change lands here before the work starts. The pid is what makes a second
# installer refusable on liveness rather than on a clock: a cold build on a small machine outlives
# any timeout worth setting, and two builds in one checkout end as a binary nobody can start.
phase() {
  [ "$MODE" = "update" ] || return 0
  printf '{"phase":"%s","startedAt":"%s","pid":%s%s}\n' "$1" "${STARTED_AT:-$(now)}" "$$" \
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
# BRIDGE_SWIFT is the toolchain the bridge told the client it would build with. Honouring it is what
# keeps a one-press promise from failing on a PATH the status never saw.
if [ -n "${BRIDGE_SWIFT:-}" ] && [ -x "$BRIDGE_SWIFT" ]; then
  PATH="$(dirname "$BRIDGE_SWIFT"):$PATH"
  export PATH
elif ! command -v swift >/dev/null 2>&1; then
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

# A build failure reaches a phone as one sentence, so it is worth saying what actually went wrong
# rather than handing over the last twelve lines of a linker's opinion.
build_reason() {
  local tail
  tail="$(tail -c 4000 "$LOG" 2>/dev/null || true)"
  case "$tail" in
    *"No space left on device"*) printf 'the disk on that machine filled up during the build' ;;
    *"Killed"*|*"signal 9"*) printf 'the build was killed — that machine ran out of memory' ;;
    *"module compiled with Swift"*|*"module file format"*)
      printf 'the checkout needs a different Swift than the one installed there' ;;
    *) printf 'build failed — see %s' "$LOG" ;;
  esac
}

# Enough room to build. A disk that fills mid-link reports itself as an unreadable linker error, and
# the number is the one thing that makes it actionable.
check_space() {
  local free
  free="$(df -Pk "$SRC" 2>/dev/null | awk 'NR==2 {print $4}')" || return 0
  [ -n "$free" ] || return 0
  [ "$free" -ge 2000000 ] ||
    fail "only $(( free / 1024 )) MB free where the checkout lives; the build needs about 2 GB"
}

build() {
  check_space
  say "building (this takes a few minutes the first time)"
  if ! ( cd "$SRC" && swift build -c release ) >>"$LOG" 2>&1; then
    # A toolchain upgraded under a stale .build produces the same failure forever, and one clean is
    # the difference between an update that heals itself and a machine that never updates again.
    say "build failed; cleaning and trying once more"
    ( cd "$SRC" && swift package clean ) >>"$LOG" 2>&1 || true
    ( cd "$SRC" && swift build -c release ) >>"$LOG" 2>&1 || fail "$(build_reason)"
  fi
  stamp_build
}

# What the binary that was just produced was built from.
#
# `git describe` run later answers about the *directory*, which moves when somebody checks out a
# branch and runs ahead of the process for the whole stretch between a build and a restart. The
# bridge reads this file once at startup, so what it reports is a fact about itself.
stamp_build() {
  local describe commit
  describe="$( cd "$SRC" && git describe --tags --always --dirty 2>/dev/null || true )"
  commit="$( cd "$SRC" && git rev-parse --short HEAD 2>/dev/null || true )"
  printf '{"version":"%s","commit":"%s","builtAt":"%s","source":"%s"}\n' \
    "${describe:-unknown}" "${commit:-}" "$(now)" "$SRC" >"$STATE_DIR/build.json"
}

# A client app can mint the password and bake it into the install one-liner
# (`curl … | BRIDGE_PASSWORD=xxx bash`) so both sides carry the same one without
# anyone retyping it. An existing config always wins: rotating a working
# install's password would lock out every client that already has it.
write_config() {
  if [ -f "$CONFIG" ]; then
    if [ -n "${BRIDGE_PASSWORD:-}" ]; then
      local existing
      existing="$(. "$CONFIG" && printf '%s' "$BRIDGE_PASSWORD")"
      [ "$existing" = "$BRIDGE_PASSWORD" ] ||
        say "keeping the password already in $CONFIG — use the one printed below, not the one you passed"
    fi
    return 0
  fi
  local password
  password="${BRIDGE_PASSWORD:-$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)}"
  cat >"$CONFIG" <<EOF
# claude-bridge configuration. Edit, then restart the service.
export BRIDGE_PASSWORD="$password"
export BRIDGE_PORT=$PORT
# 0.0.0.0 so a phone on your tailnet can reach it; the password is what keeps it yours.
export BRIDGE_BIND=0.0.0.0
export BRIDGE_MODEL=sonnet
# export BRIDGE_APNS_KEY=\$HOME/.claude-bridge/AuthKey_XXXXXXXXXX.p8
# export BRIDGE_APNS_KEY_ID=XXXXXXXXXX
# export BRIDGE_APNS_TEAM_ID=XXXXXXXXXX
EOF
  chmod 600 "$CONFIG"
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# The runner is where a machine's own arrangements live — a toolchain on the PATH, a claude
# somewhere unusual, a store pointed elsewhere — and an update that rewrote it unattended would
# un-configure the bridge at three in the morning and look like the CLI breaking. So it is replaced
# only while it is still the file this script last wrote.
write_runner() {
  local stamp="$STATE_DIR/run.sh.sha"
  if [ -f "$RUNNER" ] && [ -f "$stamp" ] && [ "$(checksum "$RUNNER")" != "$(cat "$stamp")" ]; then
    say "keeping $RUNNER — it has been edited since this script wrote it"
    return 0
  fi
  cat >"$RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="\$HOME/.local/bin:\$HOME/.local/share/swiftly/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
[ -f "$CONFIG" ] && . "$CONFIG"
export BRIDGE_SRC="$SRC"
export BRIDGE_STATE_DIR="$STATE_DIR"
exec "$SRC/.build/release/claude-bridge"
EOF
  chmod 755 "$RUNNER"
  checksum "$RUNNER" >"$stamp"
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

  Address   http://$address:$PORT
  Username  claude
  Password  $password

Copy this one line into Tailscode's address field — it fills the password too:

  http://$address:$PORT BRIDGE_PASSWORD=$password

Or check it by hand:

  curl -u claude:$password http://$address:$PORT/health

Config    $CONFIG
Source    $SRC
Update    re-run this script, or tap Update in Tailscode
EOF
}

if [ "$MODE" = "update" ]; then
  fetch_source
  phase building
  build
  # An install predating a runner variable would never gain it otherwise, and the bridge reads the
  # build stamp through one: rewriting the launcher is what carries the new contract onto machines
  # that only ever take updates.
  write_runner
  say "built $(git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown)"
  phase restarting
  if [ -n "$MANAGED" ]; then
    exit 0
  fi
  restart_service
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
