#!/usr/bin/env bash
#
# claude-bridge installer and updater.
#
#   curl -fsSL https://raw.githubusercontent.com/guitaripod/claude-bridge/master/install.sh | bash
#
# Downloads the prebuilt release for this machine into ~/.claude-bridge/bin, writes a config with a
# generated password, and registers a service (systemd --user on Linux, launchd on macOS) so the
# bridge comes back after a reboot. No Swift and no git are needed for that. Only when there is no
# prebuilt release for this machine, the download fails or does not check out, or --from-source is
# given, does it clone the repo into ~/.claude-bridge/src and build it instead.
#
# Re-run it any time to update; --update is the same thing without touching config or service
# files, and is what the bridge runs when a client asks it to update itself. --no-service installs
# everything except the service. A machine that already builds from source keeps doing so.
#
# A client app that already minted a password can pass it through the pipe:
#
#   curl -fsSL https://raw.githubusercontent.com/guitaripod/claude-bridge/master/install.sh | BRIDGE_PASSWORD=xxx bash

# shellcheck disable=SC1090
set -euo pipefail

REPO="https://github.com/guitaripod/claude-bridge"
RELEASE_BASE="${BRIDGE_RELEASE_BASE:-$REPO/releases/latest/download}"
RELEASE_BASE="${RELEASE_BASE%/}"
SRC="${BRIDGE_SRC:-$HOME/.claude-bridge/src}"
STATE_DIR="${BRIDGE_STATE_DIR:-$HOME/.claude-bridge}"
BIN_DIR="$STATE_DIR/bin"
CONFIG="$STATE_DIR/config.env"
RUNNER="$STATE_DIR/run.sh"
LOG="$STATE_DIR/update.log"
STATE_FILE="$STATE_DIR/update.state.json"
LABEL="${BRIDGE_LABEL:-com.guitaripod.claude-bridge}"
UNIT="${BRIDGE_UNIT:-claude-bridge.service}"
PORT="${BRIDGE_PORT:-4098}"
MODE="install"
MANAGED=""
NO_SERVICE=""
FROM_SOURCE=""
for argument in "$@"; do
  case "$argument" in
    --update) MODE="update" ;;
    # The bridge started this update and will restart itself once the build lands, so the script
    # must not touch the service: it is a child of the very thing it would be restarting.
    --managed) MANAGED="1" ;;
    --no-service) NO_SERVICE="1" ;;
    --from-source) FROM_SOURCE="1" ;;
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
# A failure records the phase it happened in, so the step a client shows as the one that broke is
# the step that broke — a check that refuses in the first second of a build would otherwise be
# blamed on the download the bridge last saw.
#
# A prebuilt install walks the same words: `running` is the download and its checks, `building` is
# putting the verified program in place, `restarting` is the hand-over, exactly as for a build.
CURRENT_PHASE=""
phase() {
  [ "$MODE" = "update" ] || return 0
  [ "$1" = failed ] || CURRENT_PHASE="$1"
  printf '{"phase":"%s","startedAt":"%s","pid":%s%s%s}\n' "$1" "${STARTED_AT:-$(now)}" "$$" \
    "$( [ -n "${2:-}" ] && printf ',"finishedAt":"%s"' "$2" )" \
    "$( [ "$1" = failed ] && [ -n "$CURRENT_PHASE" ] && printf ',"failedIn":"%s"' "$CURRENT_PHASE" )" \
    >"$STATE_FILE"
}

fail() {
  say "error: $*"
  phase failed "$(now)"
  exit 1
}

WORK=""
cleanup() { [ -z "$WORK" ] || rm -rf "$WORK"; }
trap cleanup EXIT

STARTED_AT="$(now)"
[ "$MODE" = "update" ] && phase running

LEFT_ITEMS=""

add_left() { LEFT_ITEMS="$LEFT_ITEMS$*"$'\n'; }

# Runs a command and gives up on it after a number of seconds. Everything the installer asks of
# another program (tailscale, the agent CLI, the freshly downloaded binary) must not be able to hold
# the install hostage, and it still reads this shell's standard input. The kill cannot be argued
# with, because a shell started with SIGTERM ignored passes that on to every child.
bounded() {
  local seconds="$1" pid timer status=0
  shift
  "$@" <&0 &
  pid=$!
  ( sleep "$seconds"; kill -KILL "$pid" ) >/dev/null 2>&1 &
  timer=$!
  wait "$pid" 2>/dev/null || status=$?
  kill -KILL "$timer" >/dev/null 2>&1 || true
  wait "$timer" 2>/dev/null || true
  return "$status"
}

BIN="$SRC/.build/release/claude-bridge"
DELIVERY="source"

# Which of the two ways of getting a program this run will try first. A machine that already has a
# checkout keeps building from it: its client compares that checkout with the project to know when
# it is behind, and a prebuilt binary swapped in beside a stale checkout would show an update as
# pending forever.
choose_delivery() {
  if [ -n "$FROM_SOURCE" ]; then
    say "Building from source, as you asked; that takes 5 to 15 minutes and needs Swift and git."
  elif [ -d "$SRC/.git" ]; then
    [ "$MODE" = "update" ] ||
      say "keeping the source build in $SRC — remove that folder to switch to the prebuilt program"
  else
    DELIVERY="binary"
    BIN="$BIN_DIR/claude-bridge"
  fi
}

# Falls back to the source build, with the one sentence that says why and what it costs.
fall_back_to_source() {
  DELIVERY="source"
  BIN="$SRC/.build/release/claude-bridge"
  say "Building from source instead, because $1; that takes 5 to 15 minutes and needs Swift and git."
}

detect_platform() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) printf 'linux-x86_64' ;;
    Linux-aarch64|Linux-arm64) printf 'linux-aarch64' ;;
    Darwin-arm64) printf 'darwin-arm64' ;;
  esac
}

# One download, quiet, retried on the failures a retry can cure. The exit status tells a missing
# file (22) from a network that is not there.
download() {
  curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 15 --max-time 900 \
    -o "$2" "$1" 2>>"$LOG"
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Downloads the latest release for this machine and proves it: the checksum matches and the program
# starts here. Leaves the verified program in $WORK/claude-bridge and the version in $VERSION, or
# the reason it could not in $FETCH_REASON.
VERSION=""
FETCH_REASON=""
fetch_release() {
  local platform asset expected status=0
  command -v curl >/dev/null 2>&1 || { FETCH_REASON="curl is not installed"; return 1; }
  platform="$(detect_platform)"
  [ -n "$platform" ] || {
    FETCH_REASON="there is no prebuilt program for $(uname -s) on $(uname -m)"
    return 1
  }
  find "$STATE_DIR" -maxdepth 1 -name '.download.*' -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
  WORK="$(mktemp -d "$STATE_DIR/.download.XXXXXX")"

  say "downloading the latest claude-bridge for $platform"
  download "$RELEASE_BASE/latest.txt" "$WORK/latest.txt" || status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 22 ] && FETCH_REASON="no prebuilt release has been published yet" ||
      FETCH_REASON="the prebuilt release could not be downloaded from $RELEASE_BASE"
    return 1
  fi
  VERSION="$(tr -d '[:space:]' <"$WORK/latest.txt")"
  case "$VERSION" in
    ''|*[!0-9.]*|.*|*.) FETCH_REASON="the release list at $RELEASE_BASE is not readable"; return 1 ;;
  esac

  asset="claude-bridge-$VERSION-$platform.tar.gz"
  download "$RELEASE_BASE/$asset" "$WORK/$asset" || status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 22 ] && FETCH_REASON="no prebuilt program has been published for $platform" ||
      FETCH_REASON="the prebuilt program could not be downloaded from $RELEASE_BASE"
    return 1
  fi
  download "$RELEASE_BASE/$asset.sha256" "$WORK/$asset.sha256" || {
    FETCH_REASON="the prebuilt program came without its checksum"
    return 1
  }
  expected="$(awk 'NR==1 {print $1}' "$WORK/$asset.sha256")"
  [ "$expected" = "$(checksum "$WORK/$asset")" ] || {
    FETCH_REASON="the download did not match its checksum and was thrown away"
    return 1
  }

  tar -xzf "$WORK/$asset" -C "$WORK" claude-bridge 2>>"$LOG" || {
    FETCH_REASON="the download could not be unpacked"
    return 1
  }
  chmod 755 "$WORK/claude-bridge"
  [ "$(bounded 15 "$WORK/claude-bridge" --version </dev/null 2>/dev/null || true)" = "claude-bridge $VERSION" ] || {
    FETCH_REASON="the prebuilt program does not start on this machine"
    return 1
  }
}

# Puts the verified program where the runner starts it from. The rename is what keeps a running
# bridge safe: its old file stays whole until it exits, and a crash here leaves the old program.
# The new file is touched because the bridge decides a build is waiting to be loaded by looking at
# the program's modification time, and the archive carries the time it was built, not the time it
# arrived.
install_release() {
  mkdir -p "$BIN_DIR"
  sign_binary "$WORK/claude-bridge"
  touch "$WORK/claude-bridge"
  mv -f "$WORK/claude-bridge" "$BIN_DIR/.claude-bridge.new"
  mv -f "$BIN_DIR/.claude-bridge.new" "$BIN"
  stamp_release
}

# What the program that was just installed is, in the file the bridge reads once at startup. A
# release has no commit and no checkout, so it names only its version.
stamp_release() {
  printf '{"version":"%s","builtAt":"%s"}\n' "$VERSION" "$(now)" >"$STATE_DIR/build.json"
}

require_toolchain() {
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
  if ! command -v swift >/dev/null 2>&1; then
    command -v git >/dev/null 2>&1 &&
      fail "building from source needs Swift, which is not installed — get it from https://www.swift.org/install/ and run this again"
    fail "building from source needs Swift and git, which are not installed — get Swift from https://www.swift.org/install/ and git from your package manager, then run this again"
  fi
  command -v git >/dev/null 2>&1 ||
    fail "building from source needs git, which is not installed — install it with your package manager and run this again"
}

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
  sign_binary "$( cd "$SRC" && swift build -c release --show-bin-path )/claude-bridge"
  stamp_build
}

# A macOS privacy grant (Full Disk Access, Documents, data from other apps) is kept against the
# binary's designated requirement, and the linker's ad-hoc one is a hash of this exact build: every
# update is a stranger to the grants the last one was given, and the Mac asks again for all of them.
# The build is re-signed ad hoc under the service's own identifier with a requirement that names
# only that identifier, so a grant follows the name instead of the bytes. It must stay ad hoc: a
# certificate gives the binary a team identity XProtect's behaviour rules judge as distributed,
# unnotarized software, and what the agents under the bridge do (the Claude CLI probes browser
# profile folders only the browser's own team may touch) got a certificate-signed bridge moved to
# the Trash as malware, with every later build under that identity refused at launch.
sign_binary() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  rm -f "$STATE_DIR/sign-identity"
  codesign --force --sign - --identifier "$LABEL" \
    --requirements "=designated => identifier \"$LABEL\"" "$1" >>"$LOG" 2>&1 ||
    say "could not re-sign the build; macOS will ask for its privacy permissions again"
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

# The value a name has in the config, which is what the running bridge will use whatever the
# environment of this run says.
config_value() {
  ( . "$CONFIG" >/dev/null 2>&1 && printf '%s' "${!1:-}" )
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
exec "$BIN"
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
TimeoutStopSec=15

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
  if [ -n "$NO_SERVICE" ]; then
    say "not restarting any service (--no-service)"
    return 0
  fi
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

TAILSCALE=""
find_tailscale() {
  local candidate
  if [ -n "${BRIDGE_TAILSCALE:-}" ]; then
    [ -x "$BRIDGE_TAILSCALE" ] && { TAILSCALE="$BRIDGE_TAILSCALE"; return 0; }
    return 1
  fi
  for candidate in "$(command -v tailscale 2>/dev/null || true)" \
    /usr/bin/tailscale /usr/local/bin/tailscale /opt/homebrew/bin/tailscale \
    /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { TAILSCALE="$candidate"; return 0; }
  done
  return 1
}

# Tailscale is what lets a phone reach this computer from anywhere. Without it the bridge still
# works on this computer and on the home network, so a missing or signed-out Tailscale is reported
# and the install carries on.
preflight_tailscale() {
  local output="" status=0
  if ! find_tailscale; then
    say "  Tailscale: not installed"
    add_left "Install Tailscale on this computer and on your phone (https://tailscale.com/download) and sign in to both with the same account. Until then the bridge works on this computer and on your home network only."
    return 0
  fi
  output="$(bounded 10 "$TAILSCALE" status 2>&1 </dev/null)" || status=$?
  if [ "$status" -eq 0 ]; then
    say "  Tailscale: connected"
    return 0
  fi
  case "$output" in
    *"Logged out"*|*"NeedsLogin"*|*"Log in at"*)
      say "  Tailscale: installed, but not signed in"
      add_left "Sign in to Tailscale on this computer: run  sudo tailscale up  (or open the Tailscale app) and finish the sign-in. Until then the bridge works on this computer and on your home network only." ;;
    *"stopped"*)
      say "  Tailscale: installed, but turned off"
      add_left "Turn Tailscale on: run  sudo tailscale up  (or switch it on in the Tailscale app). Until then the bridge works on this computer and on your home network only." ;;
    *)
      say "  Tailscale: installed, but not running"
      add_left "Start Tailscale: open the Tailscale app, or on Linux run  sudo systemctl enable --now tailscaled  and then  sudo tailscale up. Until then the bridge works on this computer and on your home network only." ;;
  esac
}

# The bridge is only a doorway: the conversation happens in Claude Code, which has to be on this
# computer and signed in. Whether it is signed in comes from the CLI's own answer; a CLI too old to
# give one is not reported as signed out.
preflight_agent() {
  local claude="" output="" candidate
  for candidate in "${BRIDGE_CLAUDE:-}" "$(command -v claude 2>/dev/null || true)" "$HOME/.local/bin/claude"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { claude="$candidate"; break; }
  done
  if [ -z "$claude" ]; then
    say "  Claude Code: not installed"
    add_left "Install Claude Code on this computer (https://docs.claude.com/en/docs/claude-code/setup), then run  claude  once and sign in."
    return 0
  fi
  output="$(bounded 20 "$claude" auth status --json 2>/dev/null </dev/null || true)"
  if printf '%s' "$output" | grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
    say "  Claude Code: installed and signed in"
  elif printf '%s' "$output" | grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*false'; then
    say "  Claude Code: installed, but not signed in"
    add_left "Sign in to Claude Code: run  claude  on this computer and follow the prompts."
  else
    say "  Claude Code: installed (could not check whether it is signed in)"
  fi
}

preflight() {
  say "Checking this computer:"
  preflight_tailscale
  preflight_agent
  say ""
}

# The bridge is up when it answers its own health route with its own password.
wait_for_health() {
  local password attempt=0
  command -v curl >/dev/null 2>&1 || return 0
  password="$(config_value BRIDGE_PASSWORD)"
  while [ "$attempt" -lt "${BRIDGE_HEALTH_ATTEMPTS:-10}" ]; do
    curl -fsS --max-time 2 -u "claude:$password" "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 &&
      return 0
    attempt=$(( attempt + 1 ))
    sleep 1
  done
  return 1
}

print_left() {
  local item number=1
  if [ -z "$LEFT_ITEMS" ]; then
    printf '\nNothing else is left to do on this computer.\n'
    return 0
  fi
  printf '\nWhat is left to do:\n'
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    printf '  %d. %s\n' "$number" "$item"
    number=$(( number + 1 ))
  done <<EOF
$LEFT_ITEMS
EOF
}

print_address() {
  local address password
  find_tailscale || true
  address="$( [ -n "$TAILSCALE" ] && bounded 10 "$TAILSCALE" ip -4 2>/dev/null </dev/null | head -1 || true)"
  [ -n "$address" ] || address="$(uname -n)"
  password="$(config_value BRIDGE_PASSWORD)"
  cat <<EOF

  Address   http://$address:$PORT
  Username  claude
  Password  $password

Copy this one line into Tailscode's address field — it fills the password too:

  http://$address:$PORT BRIDGE_PASSWORD=$password

Or check it by hand:

  curl -u claude:$password http://$address:$PORT/health
EOF
}

# Runs the binary's own `pair` command, in the environment the service gives it.
run_pair() {
  [ -x "$BIN" ] || return 1
  ( [ -f "$CONFIG" ] && . "$CONFIG"
    export BRIDGE_STATE_DIR="$STATE_DIR" BRIDGE_SRC="$SRC"
    exec "$BIN" pair )
}

# The pairing link and code when the installed bridge can print them, and the address and password
# the way this script always has when it cannot. `pair` is asked for rather than detected: a
# program that does not know the word exits with a usage error and prints nothing.
print_pairing() {
  local output
  if output="$(bounded 20 run_pair 2>/dev/null </dev/null)" && [ -n "$output" ]; then
    printf '\n%s\n' "$output"
  else
    print_address
  fi
}

report() {
  PORT="$(config_value BRIDGE_PORT)"
  PORT="${PORT:-4098}"
  if [ -n "$NO_SERVICE" ]; then
    printf '\nclaude-bridge is installed but not started. Start it with:  %s\n' "$RUNNER"
  elif wait_for_health; then
    printf '\nclaude-bridge is running.\n'
  else
    printf '\nclaude-bridge is installed, but it is not answering on port %s yet.\n' "$PORT"
    add_left "Find out why the bridge did not start: $( [ "$(uname -s)" = "Darwin" ] && printf 'read %s/bridge.log' "$STATE_DIR" || printf 'run  journalctl --user -u %s' "$UNIT" )"
  fi
  print_left
  print_pairing
  printf '\nConfig    %s\n' "$CONFIG"
  if [ "$DELIVERY" = "source" ]; then
    printf 'Source    %s\n' "$SRC"
    printf 'Update    re-run this script, or tap Update in Tailscode\n'
  else
    printf 'Program   %s\n' "$BIN"
    printf 'Update    re-run the install command\n'
  fi
}

choose_delivery

if [ "$MODE" = "update" ]; then
  if [ "$DELIVERY" = "binary" ]; then
    fetch_release || fail "$FETCH_REASON"
    phase building
    install_release
    say "installed claude-bridge $VERSION"
  else
    require_toolchain
    fetch_source
    phase building
    build
    say "built $(git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown)"
  fi
  # An install predating a runner variable would never gain it otherwise, and the bridge reads the
  # build stamp through one: rewriting the launcher is what carries the new contract onto machines
  # that only ever take updates.
  write_runner
  phase restarting
  if [ -n "$MANAGED" ]; then
    exit 0
  fi
  restart_service
  phase succeeded "$(now)"
  exit 0
fi

preflight

if [ "$DELIVERY" = "binary" ]; then
  fetch_release || fall_back_to_source "$FETCH_REASON"
fi
if [ "$DELIVERY" = "binary" ]; then
  install_release
  say "installed claude-bridge $VERSION"
else
  require_toolchain
  fetch_source
  build
fi
write_config
write_runner
if [ -z "$NO_SERVICE" ]; then
  if [ "$(uname -s)" = "Darwin" ]; then
    install_service_macos
  else
    install_service_linux
  fi
fi
report
