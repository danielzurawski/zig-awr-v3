#!/usr/bin/env bash
# Mac-side driver for the AWR-V3 in-situ acceptance test. Pushes the
# zig-awr-v3 repo to the connected Raspberry Pi over rsync+SSH, kicks
# off `scripts/in-situ-test.sh` on the Pi, and (optionally) verifies
# the WebSocket protocol contract from THIS host afterwards — which is
# the path the dashboard would actually take.
#
# Requirements:
#   - Passwordless SSH access to the Pi (key auth).
#   - Pi running Raspberry Pi OS Bookworm with the Adeept HAT.
#   - The repo this script lives in (zig-awr-v3) checked out locally.
#
# Usage:
#   scripts/run-in-situ-test.sh \
#       [--host raspberry-pi.local] [--user dmz] \
#       [--no-motion] [--with-slam] [--allow-low-battery] \
#       [--keep-zig|--keep-vendor|--keep-current] \
#       [--remote-protocol] [--no-rsync]
#
# Exit code: forwards the Pi-side script's exit code (0 = all phases
# passed). The optional remote-protocol step is logged but does not
# change the exit code.

set -euo pipefail

HOST="raspberry-pi.local"
USER_NAME="dmz"
PI_REPO_DIR="/home/$USER_NAME/zig-awr-v3"
NO_MOTION=0
WITH_SLAM=0
ALLOW_LOW_BATTERY=0
RESTORE_FLAG=""
REMOTE_PROTOCOL=0
NO_RSYNC=0
SSH_OPTS=( -o "ConnectTimeout=10" -o "ServerAliveInterval=15" -o "BatchMode=yes" )

REPO_ROOT="$(cd "$(dirname "$0")/.."; pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --user) USER_NAME="$2"; PI_REPO_DIR="/home/$USER_NAME/zig-awr-v3"; shift 2;;
    --no-motion)         NO_MOTION=1; shift;;
    --with-slam)         WITH_SLAM=1; shift;;
    --allow-low-battery) ALLOW_LOW_BATTERY=1; shift;;
    --keep-zig)     RESTORE_FLAG="--keep-zig"; shift;;
    --keep-vendor)  RESTORE_FLAG="--keep-vendor"; shift;;
    --keep-current) RESTORE_FLAG="--keep-current"; shift;;
    --remote-protocol) REMOTE_PROTOCOL=1; shift;;
    --no-rsync) NO_RSYNC=1; shift;;
    --pi-repo-dir) PI_REPO_DIR="$2"; shift 2;;
    -h|--help) sed -n '1,30p' "$0"; exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

target="$USER_NAME@$HOST"

# ───────────────────────── reachability probe ─────────────────────────
echo "[mac] Probing $target ..."
PROBE_OUT=""
for attempt in 1 2 3 4 5; do
  if PROBE_OUT=$(ssh "${SSH_OPTS[@]}" "$target" 'hostname; uname -m; uptime -p; uname -r' 2>&1); then
    echo "$PROBE_OUT" | sed 's/^/  /'
    break
  fi
  echo "  attempt $attempt failed, retrying in 6s..."
  sleep 6
done
if [ -z "$PROBE_OUT" ]; then
  echo "[mac] Pi unreachable after 5 attempts. Verify it has finished booting and is on the same Wi-Fi/LAN."
  exit 2
fi

# ───────────────────────── sync the repo ─────────────────────────
if [ "$NO_RSYNC" = 0 ]; then
  echo "[mac] Syncing $REPO_ROOT -> $target:$PI_REPO_DIR"
  rsync -a --delete \
    --exclude '.git' --exclude 'zig-cache' --exclude 'zig-out' \
    --exclude '.zig-cache' --exclude 'node_modules' \
    --exclude '/build' \
    "$REPO_ROOT/" "$target:$PI_REPO_DIR/"
else
  echo "[mac] --no-rsync: assuming repo already at $target:$PI_REPO_DIR"
fi

# ───────────────────────── invoke the Pi-side runner ─────────────────────────
PI_ARGS=( --user "$USER_NAME" )
[ "$NO_MOTION" = 1 ]         && PI_ARGS+=( --no-motion )
[ "$WITH_SLAM" = 1 ]         && PI_ARGS+=( --with-slam )
[ "$ALLOW_LOW_BATTERY" = 1 ] && PI_ARGS+=( --allow-low-battery )
[ -n "$RESTORE_FLAG" ]       && PI_ARGS+=( "$RESTORE_FLAG" )

echo "[mac] Running scripts/in-situ-test.sh on the Pi (sudo)..."
echo "[mac]   args: ${PI_ARGS[*]}"
set +e
ssh "${SSH_OPTS[@]}" -t "$target" \
  "sudo bash $PI_REPO_DIR/scripts/in-situ-test.sh ${PI_ARGS[*]}"
RC=$?
set -e
echo "[mac] Pi-side runner exited with $RC"

# ───────────────────────── remote protocol (optional) ─────────────────────────
if [ "$REMOTE_PROTOCOL" = 1 ]; then
  # The protocol test driver uses Node 22's built-in WebSocket. If this
  # Mac doesn't have Node 22+ yet, refuse to run rather than toggling the
  # Pi's Zig service to active and then failing — that's exactly the
  # state ("wheels still spinning after the test") we want to avoid.
  MAC_NODE_OK=0
  if command -v node >/dev/null 2>&1; then
    if node --version 2>/dev/null | grep -qE '^v(2[2-9]|[3-9][0-9])\.'; then
      MAC_NODE_OK=1
    fi
  fi
  if [ "$MAC_NODE_OK" = 0 ]; then
    echo "[mac] Skipping --remote-protocol: Node 22+ is required on the Mac for"
    echo "[mac]   the ws-protocol-test driver (uses the built-in WebSocket)."
    echo "[mac]   Install with:  brew install node@22  (or 'nvm install 22 && nvm use 22')"
    echo "[mac]   The Pi-side runner already exercised the full protocol locally,"
    echo "[mac]   so this is purely the LAN-reachability sanity check."
  else
    echo "[mac] Bringing up the Zig service on the Pi for end-to-end LAN test..."
    ssh "${SSH_OPTS[@]}" "$target" "sudo /usr/local/bin/awr-stack zig" || true
    sleep 2
    if (echo > /dev/tcp/$HOST/8889) 2>/dev/null; then
      echo "[mac] Pi :8889 reachable; running ws-protocol-test from Mac..."
      SLAM_FLAG=0; [ "$WITH_SLAM" = 1 ] && [ "$NO_MOTION" = 0 ] && SLAM_FLAG=1
      SKIP=0;     [ "$NO_MOTION" = 1 ] && SKIP=1
      if WS_URL="ws://$HOST:8889" \
         INCLUDE_SLAM="$SLAM_FLAG" \
         WS_SKIP_MOTION="$SKIP" \
         BACKEND_LABEL="zig-from-mac" \
         node "$REPO_ROOT/scripts/acceptance/ws-protocol-test.mjs"; then
        echo "[mac] LAN-side ws-protocol-test PASSED (slam=$SLAM_FLAG, skip_motion=$SKIP)"
      else
        echo "[mac] LAN-side ws-protocol-test FAILED — see stderr"
      fi
    else
      echo "[mac] Pi :8889 not reachable from this host; check firewall / Wi-Fi"
    fi
    # Even if the LAN test failed, restore the Pi to a known-quiet state:
    # leave whatever the in-situ runner originally set up, but ensure no
    # motors are running. awr-stack stop disables both services AND the
    # vendor service's last action zeroes motors via Move.motorStop().
    echo "[mac] Quiescing Pi services (awr-stack stop) so the robot is at rest..."
    ssh "${SSH_OPTS[@]}" "$target" "sudo /usr/local/bin/awr-stack stop || true" || true
    # Also actively stop motors via the vendor's PCA9685 driver, in case
    # the binary was killed mid-pulse.
    ssh "${SSH_OPTS[@]}" "$target" 'sudo python3 -c "import sys; sys.path.insert(0, \"/home/'"$USER_NAME"'/Adeept_AWR-V3/Server\"); import Move; Move.setup(); Move.motorStop()" 2>/dev/null || true' || true
  fi
fi

exit $RC
