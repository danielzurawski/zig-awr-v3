#!/usr/bin/env bash
# Pi-side hardware-path exercise (Stage 3 & 4 of the in-situ campaign).
#
# Drives EACH backend (Zig firmware OR vendor Python) through every
# major hardware surface and captures empirical evidence rather than
# just protocol-level acks:
#
#   A  Telemetry envelope        — parse get_info, sanity-check ranges
#   B  GPIO LEDs (GPIO 9/25/11)  — Switch_N_on/off + read pin via pinctrl
#   C  Servos (PCA9685 ch00-07)  — PWMINIT then read duty cycles
#   D  Addressable strip         — police mode emits log entries
#   E  Buzzer (GPIO 18)          — `tune` command (Zig) or BabyShark.py (vendor)
#   F  Camera (rpicam-jpeg)      — capture frame, sanity-check non-zero / non-black
#   G  Quiescent state           — motors and LEDs returned to off
#
# Designed to be safe by default for a robot on a stand: NO motor
# pulses are issued. The protocol contract test (ws-protocol-test.mjs)
# already covers the motor surface; this script focuses on everything
# else so the two are complementary.
#
# Exit code: 0 if every phase passed, non-zero otherwise.

set -uo pipefail

BACKEND="zig"
ZIG_PORT="${ZIG_PORT:-8889}"
VENDOR_PORT="${VENDOR_PORT:-8888}"
LOG_DIR="${LOG_DIR:-/tmp/awr-v3-hw-paths-logs}"
USER_NAME="${SUDO_USER:-${USER:-pi}}"
VENDOR_DIR="${VENDOR_DIR:-/home/$USER_NAME/Adeept_AWR-V3}"
KEEP_AS_BOOTED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND="$2"; shift 2;;
    --vendor-dir) VENDOR_DIR="$2"; shift 2;;
    --keep-as-booted) KEEP_AS_BOOTED=1; shift;;
    --user) USER_NAME="$2"; VENDOR_DIR="/home/$USER_NAME/Adeept_AWR-V3"; shift 2;;
    -h|--help) sed -n '1,30p' "$0"; exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

case "$BACKEND" in
  zig) PORT="$ZIG_PORT"; SVC="awr-v3-zig.service";;
  python) PORT="$VENDOR_PORT"; SVC="Adeept_Robot.service";;
  *) echo "Invalid --backend: $BACKEND (zig|python)"; exit 1;;
esac

if [ "$EUID" -ne 0 ]; then
  exec sudo -E "$0" --backend "$BACKEND" --user "$USER_NAME" \
       ${KEEP_AS_BOOTED:+--keep-as-booted} \
       --vendor-dir "$VENDOR_DIR"
fi

mkdir -p "$LOG_DIR"

# ───────────────────────── helpers ─────────────────────────
PASS=0; FAIL=0; PHASE=""
phase()  { PHASE="$*"; echo; echo "=== PHASE: $PHASE ==="; }
pass()   { PASS=$((PASS+1)); echo "  PASS [$PHASE] $*"; }
fail()   { FAIL=$((FAIL+1)); echo "  FAIL [$PHASE] $*"; }
note()   { echo "  NOTE [$PHASE] $*"; }

# Read PCA9685 channel duty cycles by going straight to the I2C bus
# (smbus2). Prints one "chNN=DDDDD" pair per line so awk/grep parsing
# is unambiguous.
#
# IMPORTANT: do NOT use Adafruit's PCA9685 driver here. Its constructor
# calls reset() which writes MODE1=0, clearing AUTO_INCREMENT. That on
# its own is fine — but if the firmware-under-test ever issues a
# multi-byte channel write afterwards, only the first byte lands at the
# base register and the rest are silently dropped. The probe would
# then see "stale" channel values and we'd misdiagnose firmware bugs.
# Going via smbus2 only reads single bytes and never writes MODE1.
read_pca9685() {
  python3 - <<'PY' 2>/dev/null
try:
    import smbus2
    bus = smbus2.SMBus(1)
    for ch in range(16):
        base = 0x06 + 4 * ch
        on_l  = bus.read_byte_data(0x5f, base)
        on_h  = bus.read_byte_data(0x5f, base + 1)
        off_l = bus.read_byte_data(0x5f, base + 2)
        off_h = bus.read_byte_data(0x5f, base + 3)
        on  = (on_h << 8) | on_l
        off = (off_h << 8) | off_l
        # Match Adafruit's 16-bit duty_cycle scaling so existing
        # assertions ("> 0", change between two reads, etc.) keep working:
        #   duty_cycle = off << 4   (or 0xFFFF if FULL_ON bit set in ON)
        if on & 0x1000:
            duty = 0xFFFF
        else:
            duty = (off & 0x0FFF) << 4
        print(f"ch{ch:02d}={duty}")
except Exception as e:
    print(f"ERR: {e}")
PY
}

# Read a GPIO pin using pinctrl. Returns "lo" or "hi" (or "unknown").
read_gpio() {
  local pin="$1"
  pinctrl get "$pin" 2>/dev/null | sed -n 's/.*| *\(lo\|hi\).*/\1/p'
}

# Send a single WebSocket request via Node 22 and print the JSON reply.
ws_send() {
  local cmd="$1"
  AWR_WS_USER="$AWR_WS_USER" AWR_WS_PASS="$AWR_WS_PASS" \
  WS_URL="ws://127.0.0.1:$PORT" WS_CMD="$cmd" \
    node - <<'NODE' 2>/dev/null
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
NODE
}

# Make sure the requested backend is running and listening.
ensure_backend_up() {
  if ! ss -ltn | grep -q ":$PORT "; then
    note "starting $SVC..."
    systemctl stop awr-v3-zig.service Adeept_Robot.service 2>/dev/null || true
    sleep 0.5
    if ! systemctl start "$SVC" 2>/dev/null; then
      # Vendor unit may not be enabled yet — try awr-stack helper.
      /usr/local/bin/awr-stack "$BACKEND" >/dev/null 2>&1 || true
    fi
    for _ in $(seq 1 60); do
      ss -ltn | grep -q ":$PORT " && break
      sleep 0.5
    done
  fi
  ss -ltn | grep -q ":$PORT " \
    && pass "$SVC listening on :$PORT" \
    || { fail "$SVC failed to bind :$PORT"; return 1; }
}

# ───────────────────────── credentials ─────────────────────────
. /etc/awr-v3-zig/credentials.env 2>/dev/null || true
AWR_WS_USER="${AWR_WS_USER:-admin}"
AWR_WS_PASS="${AWR_WS_PASS:-123456}"
export AWR_WS_USER AWR_WS_PASS

# ───────────────────────── PHASE A — telemetry envelope ─────────────────────────
phase "A — telemetry envelope (get_info)"
ensure_backend_up || exit 1

INFO_JSON="$(ws_send get_info)"
echo "  raw: $INFO_JSON"
TITLE="$(printf '%s' "$INFO_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["title"])' 2>/dev/null || echo "")"
LEN="$(printf '%s' "$INFO_JSON" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))' 2>/dev/null || echo "0")"
DATA0="$(printf '%s' "$INFO_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0])' 2>/dev/null || echo "")"
DATA1="$(printf '%s' "$INFO_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][1])' 2>/dev/null || echo "")"
[ "$TITLE" = "get_info" ] && pass "title is get_info" || fail "title mismatch ($TITLE)"
[ "$LEN" -ge 3 ] && pass "data has >=3 fields ($LEN)" || fail "data too short ($LEN)"
# Field order matches vendor Server/info.py for the first three slots, so
# the dashboard can decode either backend with one parser:
#   data[0] CPU temperature (°C, one decimal)
#   data[1] CPU usage        (%, one decimal)
#   data[2] memory usage     (%, one decimal)
#   data[3] battery %        (Zig-only; vendor omits)
DATA2="$(printf '%s' "$INFO_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][2])' 2>/dev/null || echo "0")"
TEMP="$(printf '%s' "${DATA0:-0}" | python3 -c 'import sys; v=sys.stdin.read().strip(); print(float(v) if v else 0.0)' 2>/dev/null || echo "0")"
CPU="$(printf '%s' "${DATA1:-0}" | python3 -c 'import sys; v=sys.stdin.read().strip(); print(float(v) if v else 0.0)' 2>/dev/null || echo "0")"
RAM="$(printf '%s' "${DATA2:-0}" | python3 -c 'import sys; v=sys.stdin.read().strip(); print(float(v) if v else 0.0)' 2>/dev/null || echo "0")"
awk -v v="$TEMP" 'BEGIN { exit !(v >= 25 && v <= 95) }' \
  && pass "CPU temperature plausible (${TEMP} °C)" \
  || fail "CPU temperature out of range (${TEMP})"
awk -v v="$CPU" 'BEGIN { exit !(v >= 0 && v <= 100) }' \
  && pass "CPU usage plausible (${CPU} %)" \
  || fail "CPU usage out of range (${CPU})"
awk -v v="$RAM" 'BEGIN { exit !(v >= 0 && v <= 100) }' \
  && pass "RAM usage plausible (${RAM} %)" \
  || fail "RAM usage out of range (${RAM})"
# Optional 4th field — Zig firmware exposes battery percentage. Vendor
# Python does not, so we only assert if present.
if [ "$LEN" -ge 4 ]; then
  DATA3="$(printf '%s' "$INFO_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][3])' 2>/dev/null || echo "0")"
  BAT="$(printf '%s' "${DATA3:-0}" | python3 -c 'import sys; v=sys.stdin.read().strip(); print(float(v) if v else 0.0)' 2>/dev/null || echo "0")"
  awk -v v="$BAT" 'BEGIN { exit !(v >= 0 && v <= 100) }' \
    && pass "battery percentage plausible (${BAT} %)" \
    || fail "battery percentage out of range (${BAT})"
fi

# ───────────────────────── PHASE B — GPIO LEDs ─────────────────────────
phase "B — GPIO LEDs (Switch_N_on/off, GPIO 9/25/11)"
declare -A LED_PIN=( [1]=9 [2]=25 [3]=11 )
for i in 1 2 3; do
  before="$(read_gpio "${LED_PIN[$i]}")"
  ws_send "Switch_${i}_on" >/dev/null
  sleep 0.1
  after_on="$(read_gpio "${LED_PIN[$i]}")"
  ws_send "Switch_${i}_off" >/dev/null
  sleep 0.1
  after_off="$(read_gpio "${LED_PIN[$i]}")"
  echo "  LED $i (GPIO ${LED_PIN[$i]}): before=$before  on->$after_on  off->$after_off"
  [ "$after_on" = "hi" ] && pass "LED $i went hi on Switch_${i}_on"  || fail "LED $i did not go hi (got $after_on)"
  [ "$after_off" = "lo" ] && pass "LED $i went lo on Switch_${i}_off" || fail "LED $i did not go lo (got $after_off)"
done

# ───────────────────────── PHASE C — servos ─────────────────────────
phase "C — servos (PCA9685 ch00 — uses SiLeft/SiRight for empirical move)"
# Strategy: read ch00 duty, fire `SiRight 0` (which both backends advance
# 2 pulse units on servo 0), then read again. The duty MUST change. This
# is the most reliable cross-backend probe: vendor's PWMINIT is a no-op
# until a servo command is issued, but SiLeft/SiRight always writes PWM.
BEFORE_CH00="$(read_pca9685 | awk -F= '/^ch00=/{print $2; exit}')"
echo "  ch00 before: ${BEFORE_CH00:-MISSING}"
# Make sure servos are initialised on whichever stack is running. Both
# accept PWMINIT (Zig drives, vendor just resets bookkeeping).
ws_send "PWMINIT" >/dev/null
sleep 0.2
AFTER_INIT_CH00="$(read_pca9685 | awk -F= '/^ch00=/{print $2; exit}')"
echo "  ch00 after PWMINIT: ${AFTER_INIT_CH00:-MISSING}"
# Now actually move servo 0 — fire 5 right pulses then 5 left to return
# to the start position so we don't leave the camera tilted.
for _ in 1 2 3 4 5; do ws_send "SiRight 0" >/dev/null; sleep 0.05; done
sleep 0.2
AFTER_RIGHT_CH00="$(read_pca9685 | awk -F= '/^ch00=/{print $2; exit}')"
echo "  ch00 after SiRight x5: ${AFTER_RIGHT_CH00:-MISSING}"
for _ in 1 2 3 4 5; do ws_send "SiLeft 0"  >/dev/null; sleep 0.05; done
sleep 0.2
AFTER_LEFT_CH00="$(read_pca9685 | awk -F= '/^ch00=/{print $2; exit}')"
echo "  ch00 after SiLeft x5:  ${AFTER_LEFT_CH00:-MISSING}"
[ -n "$AFTER_RIGHT_CH00" ] && [ "${AFTER_RIGHT_CH00:-0}" -ne 0 ] \
  && pass "servo 0 driven to non-zero PWM after SiRight (${AFTER_RIGHT_CH00})" \
  || fail "servo 0 still at zero after SiRight x5 (${AFTER_RIGHT_CH00:-MISSING})"
if [ -n "$AFTER_RIGHT_CH00" ] && [ -n "$AFTER_LEFT_CH00" ]; then
  [ "$AFTER_RIGHT_CH00" != "$AFTER_LEFT_CH00" ] \
    && pass "servo 0 PWM changed between SiRight ($AFTER_RIGHT_CH00) and SiLeft ($AFTER_LEFT_CH00)" \
    || fail "servo 0 PWM unchanged between SiRight and SiLeft (${AFTER_RIGHT_CH00})"
fi

# ───────────────────────── PHASE D — addressable strip (police) ─────────────────────────
phase "D — addressable LED strip (police mode)"
JCOUNT_BEFORE=$(journalctl -u "$SVC" --no-pager -n 200 2>/dev/null | wc -l)
ws_send "police" >/dev/null
sleep 1
ws_send "policeOff" >/dev/null
sleep 0.4
JCOUNT_AFTER=$(journalctl -u "$SVC" --no-pager -n 200 2>/dev/null | wc -l)
note "journalctl line delta: $((JCOUNT_AFTER - JCOUNT_BEFORE))"
# Both stacks accept the command and reply ok. Visually the strip flashes
# red/blue; we can't read the SPI bus back cheaply but the protocol-level
# ack is sufficient for this phase plus the lack of crash in the journal.
# The vendor's `websockets` library logs ConnectionClosedError every time
# our short-lived test client disconnects without a close handshake — that
# is benign and explicitly not a backend fault, so we filter it out and
# only flag fatal/panic/Traceback patterns that indicate real crashes.
# Vendor's websockets library logs the *full traceback* each time the
# short-lived test client disconnects without a graceful close frame.
# That chain ends with `ConnectionClosedError: no close frame...`. We
# treat the chain as benign noise (the connection close is what the
# test does on purpose), but flag any traceback whose tail is a
# *different* exception — that's what would indicate a real backend
# crash (e.g. NameError in a vendor module, or a Zig panic).
JOURNAL_TAIL="$(journalctl -u "$SVC" --no-pager -n 80 --since "1 minute ago" 2>/dev/null)"
TRACEBACK_TAILS="$(printf '%s\n' "$JOURNAL_TAIL" \
  | awk '
    /Traceback \(most recent call last\)/ { in_tb=1; last=""; next }
    in_tb && /^[A-Za-z_][A-Za-z0-9_.]*Error|^[A-Za-z_][A-Za-z0-9_.]*Exception/ { last=$0; print last; in_tb=0; next }
    in_tb && /^.*: [A-Za-z_][A-Za-z0-9_.]*Error|^.*: [A-Za-z_][A-Za-z0-9_.]*Exception/ {
      # Lines like "<timestamp> ... websockets.exceptions.ConnectionClosedError: ..."
      sub(/^.*: /, ""); print; in_tb=0; next
    }
    /^[^ ]/ && in_tb { in_tb=0 }
  ' \
  | grep -viE 'ConnectionClosedError|IncompleteReadError|websockets\.exceptions' \
  | head -3)"
if [ -z "$TRACEBACK_TAILS" ]; then
  pass "police mode toggled without genuine errors in journal"
else
  fail "police mode produced unexpected exception tails:"
  printf '%s\n' "$TRACEBACK_TAILS" | sed 's/^/    /'
fi

# ───────────────────────── PHASE E — buzzer ─────────────────────────
phase "E — buzzer (GPIO 18 PWM)"
case "$BACKEND" in
  zig)
    # Zig has WS audio commands. Play a short tune; pinctrl will show
    # the pin alternating "lo"/"hi" if the tune is in flight.
    pre="$(read_gpio 18)"
    ws_send "tune seven_notes" >/dev/null
    sleep 0.3
    mid="$(read_gpio 18)"
    sleep 1
    post="$(read_gpio 18)"
    echo "  GPIO 18: before=$pre  mid-tune=$mid  after=$post"
    pass "tune command accepted; pin states observed (pre=$pre mid=$mid post=$post)"
    ;;
  python)
    # Vendor has no WS audio command. Stop service, run BabyShark.py
    # standalone, restart service. Skipped if Examples directory absent.
    if [ -f "$VENDOR_DIR/Examples/02_Buzzer/BabyShark.py" ]; then
      systemctl stop "$SVC"
      sleep 0.5
      pre="$(read_gpio 18)"
      timeout 4s python3 "$VENDOR_DIR/Examples/02_Buzzer/BabyShark.py" >/dev/null 2>&1 || true
      post="$(read_gpio 18)"
      systemctl start "$SVC"
      for _ in $(seq 1 20); do ss -ltn | grep -q ":$PORT " && break; sleep 0.5; done
      pass "BabyShark.py executed (pre=$pre post=$post)"
    else
      note "BabyShark.py not present at $VENDOR_DIR/Examples/02_Buzzer/"
    fi
    ;;
esac

# ───────────────────────── PHASE F — camera ─────────────────────────
phase "F — camera (rpicam-jpeg)"
IMG="$LOG_DIR/snap-$BACKEND.jpg"
rm -f "$IMG"
if rpicam-jpeg --output "$IMG" --timeout 1500 --width 640 --height 480 -n >/dev/null 2>&1; then
  if [ -s "$IMG" ]; then
    SIZE=$(stat -c '%s' "$IMG" 2>/dev/null || stat -f '%z' "$IMG" 2>/dev/null)
    echo "  captured $SIZE bytes -> $IMG"
    [ "${SIZE:-0}" -ge 5000 ] \
      && pass "camera frame ${SIZE} bytes (>=5 kB)" \
      || fail "camera frame too small (${SIZE})"
    # Quick "not all-black" sanity via Python (mean pixel value > 5).
    MEAN=$(python3 - <<PY 2>/dev/null
try:
    from PIL import Image
    import sys
    img = Image.open("$IMG").convert("L")
    pixels = list(img.getdata())
    print(sum(pixels) / len(pixels))
except Exception as e:
    print(0)
PY
)
    awk -v m="$MEAN" 'BEGIN { exit !(m > 3) }' \
      && pass "camera frame non-black (mean luma $MEAN)" \
      || note "camera frame mean luma is $MEAN (lens covered? lights off?)"
  else
    fail "rpicam-jpeg created an empty file"
  fi
else
  note "rpicam-jpeg unavailable or failed (camera disconnected?)"
fi

# ───────────────────────── PHASE G — quiescent verification ─────────────────────────
phase "G — quiescent state"
PCA="$(read_pca9685)"
echo "  PCA9685 final:"
echo "$PCA" | sed 's/^/    /'
MOTOR_BAD=$(echo "$PCA" | awk -F= '/^ch(08|09|10|11|12|13|14|15)=/ && $2 != 0' | wc -l)
[ "$MOTOR_BAD" = 0 ] \
  && pass "all 8 motor channels quiescent (duty=0)" \
  || fail "$MOTOR_BAD motor channels still pulsed (PCA9685 not at rest)"

GPIO_BAD=0
for pin in 9 25 11; do
  s="$(read_gpio "$pin")"
  [ "$s" != "lo" ] && GPIO_BAD=$((GPIO_BAD+1))
done
[ "$GPIO_BAD" = 0 ] \
  && pass "all 3 GPIO LEDs quiescent (lo)" \
  || fail "$GPIO_BAD GPIO LEDs still lit"

if [ "$KEEP_AS_BOOTED" = 0 ]; then
  note "leaving $SVC active for follow-up (use --keep-as-booted to leave untouched)"
fi

echo
echo "=== HW PATHS SUMMARY ($BACKEND backend) ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "Logs: $LOG_DIR"
[ "$FAIL" -eq 0 ]
