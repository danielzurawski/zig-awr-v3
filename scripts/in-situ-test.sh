#!/usr/bin/env bash
# In-situ functional acceptance for the Adeept AWR-V3 Zig + dual-stack
# install. Designed to run ON the Raspberry Pi itself, against real
# hardware (GPIO, I2C, SPI, motors, ultrasonic, lights). Mirrors the
# Docker acceptance phases but with hardware-aware assertions.
#
# Safe by default:
#  - Assumes the robot is on a stand with wheels clear of the floor;
#    the WebSocket protocol contract test sends short motor pulses.
#    Pass `--no-motion` to skip the motion-exercising sections.
#  - Reads the battery voltage up-front and refuses to run motor tests
#    below 50% unless `--allow-low-battery` is given.
#  - Snapshots the systemd state of `Adeept_Robot.service` and
#    `awr-v3-zig.service` and restores it at the end (so a flip to
#    Zig won't leave you stuck with the wrong service enabled).
#
# Usage:
#   sudo bash scripts/in-situ-test.sh [--user dmz] [--no-motion] \
#                                     [--with-slam] [--allow-low-battery] \
#                                     [--keep-zig|--keep-vendor|--keep-current] \
#                                     [--rehearsal]
#
# `--rehearsal` is a Docker / non-Pi mode for validating the script's
# own logic without hardware. It auto-enables when /.dockerenv exists.
# In rehearsal mode the runner:
#   - skips /dev/gpiomem, /dev/i2c-1, /dev/spidev0.0, i2cdetect probes (NOTE)
#   - skips ADS7830 battery readout (NOTE), forces --no-motion
#   - forces --build-mode sim for install-pi.sh (no /dev/gpiomem at runtime)
#   - replaces awr-stack live-port checks with grep against
#     $SYSTEMCTL_STUB_LOG (since the systemctl stub records but does
#     not actually start services)
#   - runs the vendor WebServer.py via scripts/acceptance/run-vendor-server.sh
#     so docker/vendor_stubs/ resolve the hardware imports
#
# Exit codes: 0 = all phases passed, non-zero = at least one phase failed.

set -uo pipefail

# ───────────────────────── arg parsing ─────────────────────────
TARGET_USER="${SUDO_USER:-${USER:-pi}}"
NO_MOTION=0
WITH_SLAM=0
ALLOW_LOW_BATTERY=0
RESTORE_MODE="snapshot" # snapshot|keep-zig|keep-vendor|keep-current
REHEARSAL=0
ZIG_PORT="${ZIG_PORT:-8889}"
VENDOR_PORT="${VENDOR_PORT:-8888}"
PREFIX="${PREFIX:-/opt/awr-v3-zig}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
VENDOR_DIR="${VENDOR_DIR:-/home/$TARGET_USER/Adeept_AWR-V3}"
LOG_DIR="${LOG_DIR:-/tmp/awr-v3-in-situ-logs}"
SHORT_TIMEOUT_S=10
LONG_TIMEOUT_S=60

# Auto-detect Docker. /.dockerenv is the canonical container marker,
# and missing /dev/gpiomem on Linux is a strong fallback signal.
if [ -f /.dockerenv ] || [ ! -e /dev/gpiomem ]; then
  REHEARSAL=1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --user)              TARGET_USER="$2"; shift 2;;
    --no-motion)         NO_MOTION=1; shift;;
    --with-slam)         WITH_SLAM=1; shift;;
    --allow-low-battery) ALLOW_LOW_BATTERY=1; shift;;
    --keep-zig)          RESTORE_MODE="keep-zig"; shift;;
    --keep-vendor)       RESTORE_MODE="keep-vendor"; shift;;
    --keep-current)      RESTORE_MODE="keep-current"; shift;;
    --vendor-dir)        VENDOR_DIR="$2"; shift 2;;
    --prefix)            PREFIX="$2"; shift 2;;
    --rehearsal)         REHEARSAL=1; shift;;
    --no-rehearsal)      REHEARSAL=0; shift;;
    -h|--help)
      sed -n '1,55p' "$0"
      exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [ "$REHEARSAL" = 1 ]; then
  NO_MOTION=1   # rehearsal never drives motors
  BUILD_MODE_FLAG="sim"
else
  BUILD_MODE_FLAG="real"
fi

if [ "$EUID" -ne 0 ]; then
  echo "[in-situ] Re-running with sudo..."
  exec sudo -E "$0" "$@" --user "$TARGET_USER"
fi

mkdir -p "$LOG_DIR"

# ───────────────────────── helpers ─────────────────────────
PASS=0
FAIL=0
PHASE=""
phase()  { PHASE="$*"; echo; echo "=== PHASE: $PHASE ==="; }
pass()   { PASS=$((PASS+1)); echo "  PASS [$PHASE] $*"; }
fail()   { FAIL=$((FAIL+1)); echo "  FAIL [$PHASE] $*"; }
note()   { echo "  NOTE [$PHASE] $*"; }
have()   { command -v "$1" >/dev/null 2>&1; }

# Last-resort safety net: regardless of how this script exits (success,
# failure, ^C, kill -TERM), zero the PCA9685 motor channels via the
# vendor's own Move.motorStop(). The PCA9685 retains PWM duty cycles
# across host-process restarts, so without this an interrupted SLAM run
# leaves the wheels spinning. Best-effort only — never fails the test.
emergency_motor_stop() {
  if [ "${REHEARSAL:-0}" = 1 ]; then return 0; fi
  if ! [ -d "${VENDOR_DIR:-/dev/null}/Server" ]; then return 0; fi
  python3 - <<PY 2>/dev/null || true
import sys
sys.path.insert(0, "${VENDOR_DIR}/Server")
try:
    import Move
    try: Move.setup()
    except Exception: pass
    try: Move.motorStop()
    except Exception: pass
except Exception:
    pass
PY
}
trap emergency_motor_stop EXIT

assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3 (got '$1')"; else fail "$3 (expected '$2', got '$1')"; fi
}
assert_file_present() { if [ -f "$1" ]; then pass "$2"; else fail "$2 (missing $1)"; fi; }
assert_dev_present()  { if [ -e "$1" ]; then pass "$2"; else fail "$2 (missing $1)"; fi; }

wait_for_port() {
  local port="$1" timeout="${2:-$SHORT_TIMEOUT_S}"
  local end=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$end" ]; do
    (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}

stop_service() { systemctl stop "$1" 2>/dev/null || true; }

snapshot_unit_state() {
  local svc="$1"
  # Use the dedicated query (cheaper + paging-proof) instead of grepping
  # `list-unit-files`, which on some systemd versions emits a pager
  # header that defeats the `^$svc` anchor.
  local lookup
  lookup="$(systemctl list-unit-files --no-legend --type=service "$svc" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -n "$lookup" ]; then
    local enabled active
    enabled="$(systemctl is-enabled "$svc" 2>/dev/null || echo 'disabled')"
    active="$(systemctl is-active  "$svc" 2>/dev/null || echo 'inactive')"
    echo "$enabled,$active"
  else
    echo "missing,missing"
  fi
}

restore_unit_state() {
  local svc="$1" want_enabled="$2" want_active="$3"
  if [ "$want_enabled" = "missing" ]; then return; fi
  case "$want_enabled" in
    enabled) systemctl enable "$svc" >/dev/null 2>&1 || true;;
    *)       systemctl disable "$svc" >/dev/null 2>&1 || true;;
  esac
  case "$want_active" in
    active|activating|reloading) systemctl start "$svc" >/dev/null 2>&1 || true;;
    *)                           systemctl stop  "$svc" >/dev/null 2>&1 || true;;
  esac
}

read_battery_voltage() {
  python3 - <<'PY' 2>&1
import sys
try:
    import board, busio
    from adafruit_bus_device.i2c_device import I2CDevice
    i2c = busio.I2C(board.SCL, board.SDA)
    dev = I2CDevice(i2c, 0x48)
    Vref, R15, R17 = 8.4, 3000.0, 1000.0
    DivisionRatio = R17 / (R15 + R17)
    cmd, channel = 0x84, 0
    control = cmd | (((channel << 2 | channel >> 1) & 0x07) << 4)
    buf = bytearray(1)
    dev.write_then_readinto(bytes([control]), buf)
    A0V = (buf[0] / 255.0) * 5.0
    V = A0V / DivisionRatio
    pct = max(0.0, (V - 6.75) / (Vref - 6.75) * 100.0)
    print(f"{V:.2f},{pct:.1f}")
except Exception as e:
    print(f"ERR: {e}", file=sys.stderr)
    sys.exit(2)
PY
}

# Convenience: how the protocol test should be invoked.
proto_test() {
  local url="$1" label="$2" log="$3" include_slam="${4:-0}" skip_motion="${5:-0}"
  WS_URL="$url" \
  BACKEND_LABEL="$label" \
  INCLUDE_SLAM="$include_slam" \
  WS_SKIP_MOTION="$skip_motion" \
    node "$REPO_DIR/scripts/acceptance/ws-protocol-test.mjs" \
    > "$log" 2>&1
}

# ───────────────────────── snapshot existing state ─────────────────────────
PYTHON_SVC="Adeept_Robot.service"
ZIG_SVC="awr-v3-zig.service"

VENDOR_BEFORE="$(snapshot_unit_state "$PYTHON_SVC")"
ZIG_BEFORE="$(snapshot_unit_state "$ZIG_SVC")"

# ───────────────────────── PHASE A — environment sanity ─────────────────────────
phase "A — environment & hardware sanity"
echo "  uname:      $(uname -a)"
echo "  os-release: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
echo "  rehearsal:  $REHEARSAL"
if [ "$REHEARSAL" = 1 ]; then
  note "rehearsal mode: skipping Pi-only hardware probes (gpiomem/i2c/spi/i2cdetect)"
else
  # Stop both robot services up front so the I2C bus is fully ours during
  # i2cdetect. Otherwise an active Adeept_Robot.service or awr-v3-zig.service
  # holds the bus and i2cdetect can miss devices (race we hit on 2026-04-29).
  note "stopping any running robot services before hardware probes"
  stop_service "$PYTHON_SVC"
  stop_service "$ZIG_SVC"
  sleep 0.5

  if grep -q "Raspberry Pi" /sys/firmware/devicetree/base/model 2>/dev/null; then
    pass "running on Raspberry Pi ($(tr -d '\0' < /sys/firmware/devicetree/base/model))"
  else
    fail "not detected as Raspberry Pi (sysfs model missing)"
  fi
  assert_dev_present /dev/gpiomem      "GPIO mem device available"
  assert_dev_present /dev/i2c-1        "I2C bus 1 available"
  assert_dev_present /dev/spidev0.0    "SPI dev 0.0 available"
  if have i2cdetect; then
    pass "i2cdetect available"
    I2C_LOG="$LOG_DIR/i2cdetect.log"
    i2cdetect -y 1 > "$I2C_LOG" 2>&1 || true
    echo "  --- i2cdetect -y 1 (truncated) ---"
    sed -n '1,12p' "$I2C_LOG" | sed 's/^/    /'
    # The Adeept HAT V3.2 has the PCA9685 jumpered to 0x5f (not the chip
    # default 0x40); both vendor Move.py and our Zig HAL use 0x5f. ADS7830
    # battery ADC sits at 0x48. Match either column position because the
    # i2cdetect grid changes every 16 addresses.
    if grep -qE "^50:.* 5f( |$)" "$I2C_LOG"; then
      pass "PCA9685 servo+motor controller @ 0x5f detected"
    else
      fail "PCA9685 @ 0x5f missing on I2C bus 1 — check HAT seating"
    fi
    if grep -qE "^40: .* 48( |$)" "$I2C_LOG"; then
      pass "ADS7830 ADC @ 0x48 detected"
    else
      fail "ADS7830 @ 0x48 missing on I2C bus 1"
    fi
  else
    note "i2cdetect missing (apt install i2c-tools)"
  fi
fi

# Node 22+ is a hard requirement for ws-protocol-test.mjs (built-in
# WebSocket landed in Node 22). install-pi.sh installs it as a first-class
# dependency, but if a user is running the in-situ test before they've
# installed the Zig stack we still bootstrap Node here as a courtesy.
# Skipped in rehearsal (Docker image already has Node 22).
need_node22=1
if have node; then
  if node --version | grep -qE '^v(2[2-9]|[3-9][0-9])\.'; then need_node22=0; fi
fi
if [ "$need_node22" = 1 ] && [ "$REHEARSAL" = 0 ]; then
  note "Node 22+ missing; installing via NodeSource (one-time, ~30 s; install-pi.sh would do this too)"
  NODE_LOG="$LOG_DIR/node-install.log"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > "$NODE_LOG" 2>&1
  apt-get install -y --no-install-recommends nodejs >> "$NODE_LOG" 2>&1
fi
have node && pass "node available ($(node --version))" || fail "node missing"
have npm  && pass "npm available  ($(npm --version))"  || fail "npm missing"
have python3 && pass "python3 available ($(python3 --version 2>&1))" || fail "python3 missing"

# ───────────────────────── PHASE B — battery check ─────────────────────────
phase "B — battery sanity (gates motor-exercising phases)"
if [ "$REHEARSAL" = 1 ]; then
  BAT_VOLTS="n/a"; BAT_PCT="n/a"; RAW_PCT=0
  note "rehearsal mode: skipping ADS7830 battery readout (no I2C in container)"
else
  BAT_OUT="$(read_battery_voltage 2>/dev/null || echo 'ERR,ERR')"
  BAT_VOLTS="${BAT_OUT%%,*}"
  BAT_PCT="${BAT_OUT##*,}"
  if [ "$BAT_VOLTS" = "ERR" ] || [ -z "$BAT_VOLTS" ]; then
    fail "could not read battery (ADS7830 channel 0)"
    RAW_PCT=0
  else
    echo "  Battery: ${BAT_VOLTS} V  (${BAT_PCT} %)"
    RAW_PCT=$(printf '%.0f' "$BAT_PCT" 2>/dev/null || echo 0)
    if [ "$RAW_PCT" -lt 20 ]; then
      fail "battery critically low (<20%) — charge before motor tests"
    elif [ "$RAW_PCT" -lt 50 ]; then
      note "battery below 50% — motor tests may brown out the rail"
      pass "battery readable at $BAT_VOLTS V"
    else
      pass "battery healthy (${BAT_PCT}% at ${BAT_VOLTS} V)"
    fi
  fi

  # Force --no-motion if battery is low (unless explicitly overridden).
  if [ "$NO_MOTION" = 0 ] && [ "$RAW_PCT" -lt 50 ] && [ "$ALLOW_LOW_BATTERY" = 0 ]; then
    note "auto-enabling --no-motion (use --allow-low-battery to override)"
    NO_MOTION=1
  fi
fi

# ───────────────────────── PHASE C — pre-existing service inventory ─────────────────────────
phase "C — pre-existing service inventory"
echo "  $PYTHON_SVC: $VENDOR_BEFORE"
echo "  $ZIG_SVC:    $ZIG_BEFORE"
[ -d "$VENDOR_DIR" ] && pass "vendor source present at $VENDOR_DIR" \
  || note "vendor source not at $VENDOR_DIR (vendor-side phases will skip)"
if [ "${VENDOR_BEFORE%,*}" = "missing" ] && [ ! -d "$VENDOR_DIR" ]; then
  HAVE_VENDOR=0
else
  HAVE_VENDOR=1
fi

# Stop both services so the in-situ phases own the hardware exclusively.
note "stopping any running robot services for the duration of the test"
stop_service "$PYTHON_SVC"
stop_service "$ZIG_SVC"

# ───────────────────────── PHASE D — install Zig stack ─────────────────────────
phase "D — install Zig stack (--build-mode $BUILD_MODE_FLAG)"
INSTALL_LOG="$LOG_DIR/install.log"
bash "$REPO_DIR/scripts/install-pi.sh" \
  --user "$TARGET_USER" \
  --prefix "$PREFIX" \
  --build-mode "$BUILD_MODE_FLAG" > "$INSTALL_LOG" 2>&1
INSTALL_RC=$?
if [ "$INSTALL_RC" != 0 ]; then
  echo "  --- install.log (last 40 lines) ---"
  tail -40 "$INSTALL_LOG" | sed 's/^/    /'
fi
assert_eq "$INSTALL_RC" "0" "install-pi.sh ($BUILD_MODE_FLAG mode) exits 0"

assert_file_present "$PREFIX/zig-out/bin/awr-v3"     "binary built at $PREFIX/zig-out/bin/awr-v3"
assert_file_present "/etc/systemd/system/$ZIG_SVC"   "systemd unit installed"
assert_file_present "/etc/awr-v3-zig/credentials.env" "credentials env file"
[ -x /usr/local/bin/awr-stack ] && pass "awr-stack helper installed" || fail "awr-stack missing"
# Note: the Zig binary does not implement --help; it begins serving on
# :$ZIG_PORT immediately. Phase E exercises the boot path properly.

# ───────────────────────── PHASE E — Zig binary boots and serves WS ─────────────────────────
phase "E — Zig binary boots and serves WebSocket on :$ZIG_PORT"
# shellcheck disable=SC1091
. /etc/awr-v3-zig/credentials.env
export AWR_WS_USER AWR_WS_PASS

stop_service "$PYTHON_SVC"
stop_service "$ZIG_SVC"

ZIG_LOG="$LOG_DIR/zig-binary.log"
"$PREFIX/zig-out/bin/awr-v3" > "$ZIG_LOG" 2>&1 &
ZIG_PID=$!
if wait_for_port "$ZIG_PORT" "$LONG_TIMEOUT_S"; then
  pass "Zig binary listening on :$ZIG_PORT"
  PROTO_LOG="$LOG_DIR/zig-protocol-localhost.log"
  SLAM_FLAG=0; [ "$WITH_SLAM" = 1 ] && [ "$NO_MOTION" = 0 ] && SLAM_FLAG=1
  SKIP_MOT=0; [ "$NO_MOTION" = 1 ] && SKIP_MOT=1
  if proto_test "ws://127.0.0.1:$ZIG_PORT" "zig-localhost" "$PROTO_LOG" "$SLAM_FLAG" "$SKIP_MOT"; then
    pass "ws-protocol-test passed against Zig binary on localhost (slam=$SLAM_FLAG, skip_motion=$SKIP_MOT)"
    tail -1 "$PROTO_LOG" | sed 's/^/    summary: /'
  else
    fail "ws-protocol-test against localhost Zig binary"
    echo "  --- last 30 lines ---"; tail -30 "$PROTO_LOG" | sed 's/^/    /'
  fi
else
  fail "Zig binary did not bind :$ZIG_PORT within ${LONG_TIMEOUT_S}s"
  echo "  --- last 40 lines of zig-binary.log ---"
  tail -40 "$ZIG_LOG" | sed 's/^/    /'
fi
kill "$ZIG_PID" 2>/dev/null || true
wait "$ZIG_PID" 2>/dev/null || true

# ───────────────────────── PHASE F — awr-stack toggle ─────────────────────────
if [ "$REHEARSAL" = 1 ]; then
  phase "F — awr-stack toggle (rehearsal: assert systemctl stub log)"
  STUB_LOG="${SYSTEMCTL_STUB_LOG:-/var/log/stub-systemctl.log}"
  : > "$STUB_LOG" 2>/dev/null || true
  awr-stack zig > "$LOG_DIR/awr-stack-zig.log" 2>&1 || true
  if grep -qE "stop $PYTHON_SVC" "$STUB_LOG" 2>/dev/null; then pass "awr-stack zig stops vendor (stub log)"; else fail "awr-stack zig did not stop vendor"; fi
  if grep -qE "enable.+--now.+$ZIG_SVC" "$STUB_LOG" 2>/dev/null; then pass "awr-stack zig enables --now Zig (stub log)"; else fail "awr-stack zig did not enable --now Zig"; fi

  : > "$STUB_LOG" 2>/dev/null || true
  awr-stack python > "$LOG_DIR/awr-stack-python.log" 2>&1 || true
  if grep -qE "stop $ZIG_SVC" "$STUB_LOG" 2>/dev/null; then pass "awr-stack python stops Zig (stub log)"; else fail "awr-stack python did not stop Zig"; fi
  if grep -qE "enable.+--now.+$PYTHON_SVC" "$STUB_LOG" 2>/dev/null; then pass "awr-stack python enables --now vendor (stub log)"; else fail "awr-stack python did not enable --now vendor"; fi

  : > "$STUB_LOG" 2>/dev/null || true
  awr-stack stop > "$LOG_DIR/awr-stack-stop.log" 2>&1 || true
  if grep -qE "stop $PYTHON_SVC" "$STUB_LOG" 2>/dev/null; then pass "awr-stack stop halts vendor (stub log)"; else fail "awr-stack stop did not halt vendor"; fi
  if grep -qE "stop $ZIG_SVC" "$STUB_LOG" 2>/dev/null; then pass "awr-stack stop halts Zig (stub log)"; else fail "awr-stack stop did not halt Zig"; fi

  awr-stack status > "$LOG_DIR/awr-stack-status.log" 2>&1 || true
  grep -q "$PYTHON_SVC" "$LOG_DIR/awr-stack-status.log" && pass "awr-stack status mentions vendor" || fail "awr-stack status missing vendor"
  grep -q "$ZIG_SVC"    "$LOG_DIR/awr-stack-status.log" && pass "awr-stack status mentions Zig"    || fail "awr-stack status missing Zig"
else
  phase "F — awr-stack toggle exercises real systemd"
  awr-stack zig > "$LOG_DIR/awr-stack-zig.log" 2>&1 || true
  if wait_for_port "$ZIG_PORT" "$LONG_TIMEOUT_S"; then
    pass "awr-stack zig: $ZIG_SVC active and listening on :$ZIG_PORT"
  else
    fail "awr-stack zig: $ZIG_SVC failed to bind :$ZIG_PORT"
    echo "  --- journalctl -u $ZIG_SVC (last 20) ---"
    journalctl -u "$ZIG_SVC" -n 20 --no-pager 2>&1 | sed 's/^/    /' || true
  fi

  if [ "$HAVE_VENDOR" = 1 ] && systemctl list-unit-files | grep -q "^$PYTHON_SVC"; then
    awr-stack python > "$LOG_DIR/awr-stack-python.log" 2>&1 || true
    if wait_for_port "$VENDOR_PORT" "$LONG_TIMEOUT_S"; then
      pass "awr-stack python: $PYTHON_SVC active and listening on :$VENDOR_PORT"
    else
      fail "awr-stack python: $PYTHON_SVC failed to bind :$VENDOR_PORT"
      echo "  --- journalctl -u $PYTHON_SVC (last 20) ---"
      journalctl -u "$PYTHON_SVC" -n 20 --no-pager 2>&1 | sed 's/^/    /' || true
    fi
  else
    note "vendor service not installed; skipping python-side toggle"
  fi

  awr-stack stop > "$LOG_DIR/awr-stack-stop.log" 2>&1 || true
  sleep 1
  if (echo > /dev/tcp/127.0.0.1/$ZIG_PORT) 2>/dev/null; then
    fail "awr-stack stop: $ZIG_PORT still bound"
  else
    pass "awr-stack stop halted Zig service"
  fi
  if (echo > /dev/tcp/127.0.0.1/$VENDOR_PORT) 2>/dev/null; then
    fail "awr-stack stop: $VENDOR_PORT still bound"
  else
    pass "awr-stack stop halted vendor service"
  fi

  awr-stack status > "$LOG_DIR/awr-stack-status.log" 2>&1 || true
  grep -q "$PYTHON_SVC" "$LOG_DIR/awr-stack-status.log" && pass "awr-stack status mentions vendor" || fail "awr-stack status missing vendor"
  grep -q "$ZIG_SVC"    "$LOG_DIR/awr-stack-status.log" && pass "awr-stack status mentions Zig"    || fail "awr-stack status missing Zig"
fi

# ───────────────────────── PHASE G — vendor WebServer.py boots & passes WS ─────────────────────────
phase "G — vendor WebServer.py runs and passes WS protocol subset"

# How the vendor server is launched depends on the environment:
#   - On a real Pi the hardware imports work, so we run python3 directly.
#   - In rehearsal/Docker we route through scripts/acceptance/run-vendor-server.sh
#     which sets PYTHONPATH=docker/vendor_stubs:Server: and uses python3 -P.
#
# This sets `VENDOR_PID` as a global rather than echoing it through a
# command substitution. The previous `$(launch_vendor_server)` wrapper
# detached the bg process to init (because the bg fork happens inside
# the command-substitution subshell), which broke `kill/wait` later.
launch_vendor_server() {
  local logfile="$1"
  if [ "$REHEARSAL" = 1 ]; then
    VENDOR_PREFIX="$VENDOR_DIR" VENDOR_PORT="$VENDOR_PORT" \
      bash "$REPO_DIR/scripts/acceptance/run-vendor-server.sh" > "$logfile" 2>&1 &
  else
    ( cd "$VENDOR_DIR/Server" && exec python3 -u WebServer.py ) > "$logfile" 2>&1 &
  fi
  VENDOR_PID=$!
}

if [ "$HAVE_VENDOR" = 1 ] && [ -f "$VENDOR_DIR/Server/WebServer.py" ]; then
  stop_service "$PYTHON_SVC"
  stop_service "$ZIG_SVC"
  VENDOR_LOG="$LOG_DIR/vendor-server.log"
  launch_vendor_server "$VENDOR_LOG"
  if wait_for_port "$VENDOR_PORT" "$LONG_TIMEOUT_S"; then
    pass "vendor WebServer.py listening on :$VENDOR_PORT"
    SKIP_MOT=0; [ "$NO_MOTION" = 1 ] && SKIP_MOT=1
    if proto_test "ws://127.0.0.1:$VENDOR_PORT" "vendor-localhost" \
                  "$LOG_DIR/vendor-protocol.log" 0 "$SKIP_MOT"; then
      pass "ws-protocol-test (subset) passed against vendor Python"
      tail -1 "$LOG_DIR/vendor-protocol.log" | sed 's/^/    summary: /'
    else
      fail "ws-protocol-test failed against vendor Python"
      echo "  --- last 30 lines ---"; tail -30 "$LOG_DIR/vendor-protocol.log" | sed 's/^/    /'
    fi
  else
    fail "vendor WebServer.py did not bind :$VENDOR_PORT"
    echo "  --- last 40 lines of vendor-server.log ---"
    tail -40 "$VENDOR_LOG" | sed 's/^/    /'
  fi
  kill "$VENDOR_PID" 2>/dev/null || true
  wait "$VENDOR_PID" 2>/dev/null || true
else
  note "skipping (vendor source not at $VENDOR_DIR or WebServer.py missing)"
fi

# ───────────────────────── PHASE H — dual-stack live ─────────────────────────
phase "H — dual-stack live: vendor :$VENDOR_PORT + Zig :$ZIG_PORT simultaneously"
if [ "$HAVE_VENDOR" = 1 ] && [ -f "$VENDOR_DIR/Server/WebServer.py" ]; then
  stop_service "$PYTHON_SVC"
  stop_service "$ZIG_SVC"
  launch_vendor_server "$LOG_DIR/dual-vendor.log"
  "$PREFIX/zig-out/bin/awr-v3" > "$LOG_DIR/dual-zig.log" 2>&1 &
  ZIG_PID=$!

  V_OK=0; Z_OK=0
  for _ in $(seq 1 120); do
    [ "$V_OK" = 0 ] && (echo > /dev/tcp/127.0.0.1/$VENDOR_PORT) 2>/dev/null && V_OK=1
    [ "$Z_OK" = 0 ] && (echo > /dev/tcp/127.0.0.1/$ZIG_PORT) 2>/dev/null && Z_OK=1
    [ "$V_OK" = 1 ] && [ "$Z_OK" = 1 ] && break
    sleep 0.25
  done
  [ "$V_OK" = 1 ] && pass "vendor :$VENDOR_PORT listening (concurrent)" || fail "vendor :$VENDOR_PORT not listening"
  [ "$Z_OK" = 1 ] && pass "Zig :$ZIG_PORT listening (concurrent)"       || fail "Zig :$ZIG_PORT not listening"

  if [ "$V_OK" = 1 ] && [ "$Z_OK" = 1 ]; then
    SLAM_FLAG=0; [ "$WITH_SLAM" = 1 ] && [ "$NO_MOTION" = 0 ] && SLAM_FLAG=1
    SKIP_MOT=0; [ "$NO_MOTION" = 1 ] && SKIP_MOT=1
    if proto_test "ws://127.0.0.1:$VENDOR_PORT" "vendor-dual" \
                  "$LOG_DIR/dual-vendor-proto.log" 0 "$SKIP_MOT"; then
      pass "vendor protocol test under dual-stack"
    else
      fail "vendor protocol test failed under dual-stack"
      tail -20 "$LOG_DIR/dual-vendor-proto.log" | sed 's/^/    /'
    fi
    if proto_test "ws://127.0.0.1:$ZIG_PORT" "zig-dual" \
                  "$LOG_DIR/dual-zig-proto.log" "$SLAM_FLAG" "$SKIP_MOT"; then
      pass "Zig protocol test under dual-stack (slam=$SLAM_FLAG, skip_motion=$SKIP_MOT)"
    else
      fail "Zig protocol test failed under dual-stack"
      tail -20 "$LOG_DIR/dual-zig-proto.log" | sed 's/^/    /'
    fi
  fi

  kill "$VENDOR_PID" 2>/dev/null || true
  kill "$ZIG_PID"    2>/dev/null || true
  wait "$VENDOR_PID" 2>/dev/null || true
  wait "$ZIG_PID"    2>/dev/null || true
else
  note "skipping dual-stack (vendor source not present)"
fi

# ───────────────────────── PHASE I — LAN-reachable banner ─────────────────────────
phase "I — LAN-reachable WebSocket banner (for the dashboard)"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_NAME="$(hostname).local"
echo "  IP:        ${HOST_IP:-unknown}"
echo "  hostname:  $HOST_NAME"
echo "  Connect from the dashboard via:"
echo "    ws://${HOST_IP:-$HOST_NAME}:$ZIG_PORT     (Zig firmware)"
echo "    ws://${HOST_IP:-$HOST_NAME}:$VENDOR_PORT  (vendor Python, when active)"
echo "  Auth: admin:123456 (from /etc/awr-v3-zig/credentials.env)"

# ───────────────────────── PHASE J — restore service state ─────────────────────────
phase "J — restore prior service state"
case "$RESTORE_MODE" in
  keep-zig)
    stop_service "$PYTHON_SVC"
    systemctl disable "$PYTHON_SVC" >/dev/null 2>&1 || true
    systemctl enable --now "$ZIG_SVC" >/dev/null 2>&1 || true
    note "left Zig stack as the active backend"
    ;;
  keep-vendor)
    stop_service "$ZIG_SVC"
    systemctl disable "$ZIG_SVC" >/dev/null 2>&1 || true
    systemctl enable --now "$PYTHON_SVC" >/dev/null 2>&1 || true
    note "left vendor stack as the active backend"
    ;;
  keep-current)
    note "leaving services as-is (no restore)"
    ;;
  snapshot|*)
    restore_unit_state "$PYTHON_SVC" "${VENDOR_BEFORE%,*}" "${VENDOR_BEFORE##*,}"
    restore_unit_state "$ZIG_SVC"    "${ZIG_BEFORE%,*}"    "${ZIG_BEFORE##*,}"
    note "restored to pre-test snapshot: vendor=$VENDOR_BEFORE, zig=$ZIG_BEFORE"
    ;;
esac

# Re-snapshot to confirm
VENDOR_AFTER="$(snapshot_unit_state "$PYTHON_SVC")"
ZIG_AFTER="$(snapshot_unit_state "$ZIG_SVC")"
echo "  $PYTHON_SVC after: $VENDOR_AFTER"
echo "  $ZIG_SVC after:    $ZIG_AFTER"

# ───────────────────────── summary ─────────────────────────
echo
echo "=== IN-SITU SUMMARY ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "Logs: $LOG_DIR"
echo "Battery: ${BAT_VOLTS} V (${BAT_PCT} %)"
echo "Restore mode: $RESTORE_MODE"
echo "Rehearsal mode: $REHEARSAL"
[ "$FAIL" -eq 0 ]
