#!/usr/bin/env bash
# Stage 5 — backend toggle stress test (in-situ).
#
# Drives the Pi through repeated transitions between the two backends
# (Zig firmware, vendor Python) and the OFF state, asserting after every
# transition that:
#
#   * exactly the expected service is active and listening on its port;
#   * the *other* service is fully inactive (no orphaned processes);
#   * the I2C bus is not contended (PCA9685 is reachable);
#   * a representative protocol-level command (`get_info`) round-trips on
#     the active backend (or, in OFF state, no port is listening);
#   * GPIO LEDs and motors are quiescent at every OFF transition.
#
# This is the empirical proof that `awr-stack zig | python | stop`
# never leaves the robot in a half-configured state where, say, both
# services fight over the I2C bus or one keeps the motors running.
#
# Exit code: 0 if every transition passes, non-zero otherwise.

set -uo pipefail

ZIG_PORT="${ZIG_PORT:-8889}"
VENDOR_PORT="${VENDOR_PORT:-8888}"
LOG_DIR="${LOG_DIR:-/tmp/awr-v3-toggle-logs}"
USER_NAME="${SUDO_USER:-${USER:-pi}}"
ROUNDS="${ROUNDS:-3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2;;
    --rounds) ROUNDS="$2"; shift 2;;
    -h|--help) sed -n '1,25p' "$0"; exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  exec sudo -E "$0" --user "$USER_NAME" --rounds "$ROUNDS"
fi

mkdir -p "$LOG_DIR"

# /etc/awr-v3-zig/credentials.env contains AWR_WS_USER / AWR_WS_PASS so
# both the Zig protocol and the vendor protocol's auth handshake succeed.
# shellcheck disable=SC1091
. /etc/awr-v3-zig/credentials.env 2>/dev/null || true
export AWR_WS_USER="${AWR_WS_USER:-admin}"
export AWR_WS_PASS="${AWR_WS_PASS:-123456}"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
note() { echo "  NOTE $*"; }

# ───────────────────────── helpers ─────────────────────────

# Assert a single TCP port is listening (within $1 seconds, default 6).
expect_listen() {
  local port="$1" timeout="${2:-6}" t=0
  while [ $t -lt $((timeout * 5)) ]; do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"; then
      return 0
    fi
    sleep 0.2; t=$((t+1))
  done
  return 1
}

expect_no_listen() {
  local port="$1"
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$" && return 1
  return 0
}

# Send a single auth+command round-trip via Node 22 and print the reply.
# Returns non-zero on connection or timeout failure.
ws_roundtrip() {
  local port="$1" cmd="$2"
  WS_URL="ws://127.0.0.1:$port" WS_CMD="$cmd" \
  AWR_WS_USER="$AWR_WS_USER" AWR_WS_PASS="$AWR_WS_PASS" \
  timeout 4 node - <<'NODE'
const url = process.env.WS_URL;
const cmd = process.env.WS_CMD;
const auth = `${process.env.AWR_WS_USER}:${process.env.AWR_WS_PASS}`;
const ws = new WebSocket(url);
function next() { return new Promise(r => ws.addEventListener("message", e => r(typeof e.data === "string" ? e.data : new TextDecoder().decode(e.data)), { once: true })); }
ws.addEventListener("open", async () => {
  ws.send(auth); await next();
  ws.send(cmd); console.log(await next());
  setTimeout(() => process.exit(0), 50);
});
ws.addEventListener("error", () => { console.error("WS_ERR"); process.exit(2); });
NODE
}

# Probe that the PCA9685 is reachable on I2C bus 1 at the expected
# address (0x5f for the Adeept HAT V3.2). Read the MODE1 register;
# if the bus is contended or the chip has gone away the i2cget will
# error out.
expect_pca9685() {
  if i2cget -y 1 0x5f 0x00 >/dev/null 2>&1; then return 0; fi
  return 1
}

# Verify GPIO LEDs (1, 2, 3 = pins 9, 25, 11) are all `lo` and the
# motor channels (PCA9685 ch08-ch15) are all duty=0.
expect_quiescent() {
  local bad=0
  for pin in 9 25 11; do
    local s
    s="$(pinctrl get "$pin" 2>/dev/null | sed -n 's/.*| *\(lo\|hi\).*/\1/p')"
    if [ "$s" != "lo" ]; then bad=1; note "GPIO $pin is $s (expected lo)"; fi
  done
  # Motor PWM channels 8..15 (each is 4 bytes at 0x06+4*ch)
  python3 - <<'PY' 2>/dev/null || bad=1
import sys, smbus2
bus = smbus2.SMBus(1)
fail = 0
for ch in range(8, 16):
    base = 0x06 + 4 * ch
    off_l = bus.read_byte_data(0x5f, base + 2)
    off_h = bus.read_byte_data(0x5f, base + 3)
    off = ((off_h << 8) | off_l) & 0x0FFF
    if off != 0:
        print(f"motor ch{ch} OFF={off}", file=sys.stderr)
        fail = 1
sys.exit(fail)
PY
  return $bad
}

# ───────────────────────── transition assertions ─────────────────────────

assert_zig_active() {
  local label="$1"
  systemctl is-active --quiet awr-v3-zig.service \
    && pass "[$label] awr-v3-zig.service is active" \
    || fail "[$label] awr-v3-zig.service is NOT active"
  systemctl is-active --quiet Adeept_Robot.service \
    && fail "[$label] Adeept_Robot.service should NOT be active" \
    || pass "[$label] Adeept_Robot.service is inactive"
  expect_listen "$ZIG_PORT" \
    && pass "[$label] :$ZIG_PORT listening" \
    || fail "[$label] :$ZIG_PORT not listening"
  expect_no_listen "$VENDOR_PORT" \
    && pass "[$label] :$VENDOR_PORT not listening" \
    || fail "[$label] :$VENDOR_PORT unexpectedly listening"
  expect_pca9685 \
    && pass "[$label] PCA9685 reachable on I2C bus 1" \
    || fail "[$label] PCA9685 unreachable (bus contention?)"
  local reply
  reply="$(ws_roundtrip "$ZIG_PORT" "get_info" 2>&1)"
  if printf '%s' "$reply" | grep -q '"title":"get_info"'; then
    pass "[$label] get_info round-trip succeeded"
  else
    fail "[$label] get_info round-trip failed"; echo "    reply: $reply" | head -c 200
  fi
}

assert_python_active() {
  local label="$1"
  systemctl is-active --quiet Adeept_Robot.service \
    && pass "[$label] Adeept_Robot.service is active" \
    || fail "[$label] Adeept_Robot.service is NOT active"
  systemctl is-active --quiet awr-v3-zig.service \
    && fail "[$label] awr-v3-zig.service should NOT be active" \
    || pass "[$label] awr-v3-zig.service is inactive"
  expect_listen "$VENDOR_PORT" 15 \
    && pass "[$label] :$VENDOR_PORT listening" \
    || fail "[$label] :$VENDOR_PORT not listening"
  expect_no_listen "$ZIG_PORT" \
    && pass "[$label] :$ZIG_PORT not listening" \
    || fail "[$label] :$ZIG_PORT unexpectedly listening"
  expect_pca9685 \
    && pass "[$label] PCA9685 reachable on I2C bus 1" \
    || fail "[$label] PCA9685 unreachable (bus contention?)"
  local reply
  reply="$(ws_roundtrip "$VENDOR_PORT" "get_info" 2>&1)"
  if printf '%s' "$reply" | grep -q '"title": "get_info"'; then
    pass "[$label] get_info round-trip succeeded"
  else
    fail "[$label] get_info round-trip failed"; echo "    reply: $reply" | head -c 200
  fi
}

assert_off() {
  local label="$1"
  systemctl is-active --quiet Adeept_Robot.service \
    && fail "[$label] Adeept_Robot.service still active" \
    || pass "[$label] Adeept_Robot.service inactive"
  systemctl is-active --quiet awr-v3-zig.service \
    && fail "[$label] awr-v3-zig.service still active" \
    || pass "[$label] awr-v3-zig.service inactive"
  expect_no_listen "$ZIG_PORT"    && pass "[$label] :$ZIG_PORT not listening"    || fail "[$label] :$ZIG_PORT still listening"
  expect_no_listen "$VENDOR_PORT" && pass "[$label] :$VENDOR_PORT not listening" || fail "[$label] :$VENDOR_PORT still listening"
  expect_quiescent && pass "[$label] all motors and GPIO LEDs quiescent" \
                  || fail "[$label] motors or LEDs not quiescent after stop"
}

# ───────────────────────── main loop ─────────────────────────

echo
echo "=== Toggle stress test — $ROUNDS rounds, 6 transitions per round ==="
echo "    Each round: Zig -> Python -> Zig -> stop -> Python -> stop -> Zig"
echo

for r in $(seq 1 "$ROUNDS"); do
  echo
  echo "─── ROUND $r ───────────────────────────────────────────────"
  echo

  echo "→ awr-stack zig"
  /usr/local/bin/awr-stack zig >>"$LOG_DIR/awr-stack.log" 2>&1
  sleep 2
  assert_zig_active "round=$r switch=zig#1"

  echo
  echo "→ awr-stack python"
  /usr/local/bin/awr-stack python >>"$LOG_DIR/awr-stack.log" 2>&1
  sleep 6  # vendor takes longer to boot (Adafruit HAL init)
  assert_python_active "round=$r switch=python#1"

  echo
  echo "→ awr-stack zig (back-to-back swap)"
  /usr/local/bin/awr-stack zig >>"$LOG_DIR/awr-stack.log" 2>&1
  sleep 2
  assert_zig_active "round=$r switch=zig#2"

  echo
  echo "→ awr-stack stop"
  /usr/local/bin/awr-stack stop >>"$LOG_DIR/awr-stack.log" 2>&1
  sleep 2
  assert_off "round=$r switch=stop#1"

  echo
  echo "→ awr-stack python (after full stop)"
  /usr/local/bin/awr-stack python >>"$LOG_DIR/awr-stack.log" 2>&1
  sleep 6
  assert_python_active "round=$r switch=python#2"

  echo
  echo "→ awr-stack stop"
  /usr/local/bin/awr-stack stop >>"$LOG_DIR/awr-stack.log" 2>&1
  sleep 2
  assert_off "round=$r switch=stop#2"

  echo
  echo "→ awr-stack zig (final of round, into next round)"
  /usr/local/bin/awr-stack zig >>"$LOG_DIR/awr-stack.log" 2>&1
  sleep 2
  assert_zig_active "round=$r switch=zig#3"
done

echo
echo "=== TOGGLE STRESS SUMMARY ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "Logs: $LOG_DIR"
exit $((FAIL == 0 ? 0 : 1))
