#!/usr/bin/env bash
# run-live-pi-e2e.sh — Mac-side orchestrator for the LIVE-PI Playwright
# project in `~/git/adeept-dashboard/tests/e2e/live`.
#
# Closes the test-coverage gap between
#
#   ~/git/adeept-dashboard/tests/e2e/specs/   (sim-only, fast, hermetic)
#   ~/git/zig-awr-v3/scripts/exercise-hw-paths.sh   (firmware + I²C only)
#
# by exercising the full chain UI → WS → Zig firmware → PCA9685 →
# H-bridge while assessing PWM duty cycles directly off the I²C bus.
#
# Prerequisites
#   * Robot ON A STAND with wheels free to spin.
#   * `awr-v3-zig.service` installed on the Pi (run install-pi.sh first
#     if missing).
#   * `sshpass` installed on the Mac.
#   * `npx playwright install chromium` already done.
#
# Usage
#   bash scripts/run-live-pi-e2e.sh \
#       --host raspberry-pi.local --user dmz [--password xxx]
#
# If --password is omitted we use $AWR_PI_PASSWORD or, failing that,
# rely on $SSH_AUTH_SOCK (set --use-agent).

set -uo pipefail

HOST="raspberry-pi.local"
PIUSER="${USER}"
PASSWORD="${AWR_PI_PASSWORD:-}"
USE_AGENT=0
DASHBOARD_DIR="${DASHBOARD_DIR:-$HOME/git/adeept-dashboard}"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --user) PIUSER="$2"; shift 2;;
    --password) PASSWORD="$2"; shift 2;;
    --use-agent) USE_AGENT=1; shift;;
    --dashboard-dir) DASHBOARD_DIR="$2"; shift 2;;
    -h|--help) sed -n '1,40p' "$0"; exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

[ -d "$DASHBOARD_DIR" ] || { echo "Dashboard dir not found: $DASHBOARD_DIR"; exit 1; }

if [ "$USE_AGENT" -eq 1 ]; then
  SSH_BASE=(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no)
  REMOTE="$PIUSER@$HOST"
else
  if [ -z "$PASSWORD" ]; then
    echo "Provide a password via --password or AWR_PI_PASSWORD, or pass --use-agent."
    exit 1
  fi
  command -v sshpass >/dev/null 2>&1 || { echo "sshpass missing on the Mac. brew install sshpass."; exit 1; }
  SSH_BASE=(sshpass -p "$PASSWORD" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no)
  REMOTE="$PIUSER@$HOST"
fi

ssh_pi() { "${SSH_BASE[@]}" "$REMOTE" "$@"; }

# ──────────────────────────────── helpers ────────────────────────────
emergency_stop_remote() {
  # Quiesce motors over WebSocket on the Pi itself, irrespective of
  # what the dashboard or Playwright is doing.  Best-effort.
  ssh_pi "python3 -c \"
import asyncio, websockets
async def go():
    try:
        async with websockets.connect('ws://127.0.0.1:8889') as ws:
            await ws.send('admin:123456')
            for c in ['DS','TS','UDstop']:
                await ws.send(c)
            await asyncio.sleep(0.2)
    except Exception as e:
        print(f'(emergency_stop swallowed: {e})')
asyncio.run(go())
\"" || true
}

probe_motors_remote() {
  ssh_pi "python3 -c \"
import smbus2, json
bus = smbus2.SMBus(1)
out = {}
for ch in range(8, 16):
    base = 0x06 + 4*ch
    on  = (bus.read_byte_data(0x5f, base+1) << 8) | bus.read_byte_data(0x5f, base)
    off = (bus.read_byte_data(0x5f, base+3) << 8) | bus.read_byte_data(0x5f, base+2)
    duty = 0xFFFF if (on & 0x1000) else (off & 0x0FFF) << 4
    out[f'ch{ch:02d}'] = duty
print(json.dumps(out))
\""
}

# Make absolutely sure we never leave wheels spinning on exit.
trap 'emergency_stop_remote >/dev/null 2>&1 || true' EXIT INT TERM

# ──────────────────────────────── steps ──────────────────────────────
echo "==> Verifying SSH + service status on $REMOTE"
ssh_pi 'echo CONNECTED; uptime -p; systemctl is-active awr-v3-zig.service Adeept_Robot.service' \
  || { echo "SSH failed."; exit 1; }

echo "==> Switching Pi to Zig backend (awr-stack zig)"
# `awr-stack` calls sudo internally; pipe the password via `sudo -S`
# unless we're using key/agent auth (in which case we hope the user
# configured NOPASSWD).
if [ "$USE_AGENT" -eq 1 ]; then
  ssh_pi 'sudo -n awr-stack zig 2>&1 | tail -5; sleep 2; systemctl is-active awr-v3-zig.service' \
    || { echo "Failed to switch to Zig backend (agent mode requires NOPASSWD sudo)."; exit 1; }
else
  ssh_pi "echo '$PASSWORD' | sudo -S awr-stack zig 2>&1 | tail -5; sleep 2; systemctl is-active awr-v3-zig.service" \
    || { echo "Failed to switch to Zig backend."; exit 1; }
fi

echo "==> Pre-flight: motors should be idle"
PRE=$(probe_motors_remote)
echo "    $PRE"
if echo "$PRE" | grep -Eq '"ch[0-9]+":\s*[1-9]'; then
  echo "    Motors are NOT idle — refusing to start tests."
  echo "    Emergency-stopping and aborting."
  emergency_stop_remote
  exit 1
fi

echo "==> Running Playwright live-pi suite"
cd "$DASHBOARD_DIR"
if [ "$USE_AGENT" -eq 1 ]; then
  AWR_PI_USE_AGENT=1 \
  AWR_PI_HOST="$PIUSER@$HOST" \
  AWR_PI_WS_URL="ws://$HOST:8889" \
  npm run test:e2e:live
else
  AWR_PI_PASSWORD="$PASSWORD" \
  AWR_PI_HOST="$PIUSER@$HOST" \
  AWR_PI_WS_URL="ws://$HOST:8889" \
  npm run test:e2e:live
fi
RC=$?

echo "==> Post-flight: motors should be idle"
POST=$(probe_motors_remote)
echo "    $POST"
if echo "$POST" | grep -Eq '"ch[0-9]+":\s*[1-9]'; then
  echo "    WARNING: motors not idle after suite."
  emergency_stop_remote
fi

echo "==> Live-Pi E2E suite exit code: $RC"
exit "$RC"
