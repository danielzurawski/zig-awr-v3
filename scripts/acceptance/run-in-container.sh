#!/usr/bin/env bash
# Functional acceptance orchestrator — runs inside the Docker image.
# Exits non-zero if any phase fails. Designed to be black-box: we do
# not import from the implementation; we exercise it via the same
# entry points (install-pi.sh, the compiled binary, awr-stack, the
# dashboard's npm scripts).

set -uo pipefail

ZIG_REPO="/opt/test/zig-awr-v3"
DASH_REPO="/opt/test/adeept-dashboard"
VENDOR_SRC="/opt/test/adeept-vendor"
LOG_DIR="/tmp/acceptance-logs"
SYSTEMCTL_LOG="/var/log/stub-systemctl.log"
PREFIX="/opt/awr-v3-zig"
SERVICE_FILE="/etc/systemd/system/awr-v3-zig.service"
CRED_FILE="/etc/awr-v3-zig/credentials.env"
VENDOR_PREFIX="/opt/Adeept_AWR-V3"
VENDOR_SERVICE_FILE="/etc/systemd/system/Adeept_Robot.service"
VENDOR_WIFI_SERVICE_FILE="/etc/systemd/system/wifi-hotspot-manager.service"
STARTUP_SH="/root/startup.sh"

DASH_PRESENT=0
VENDOR_PRESENT=0
[ -d "$DASH_REPO" ] && [ ! -f "$DASH_REPO/.acceptance-placeholder" ] && DASH_PRESENT=1
[ -d "$VENDOR_SRC" ] && [ ! -f "$VENDOR_SRC/.acceptance-placeholder" ] && [ -f "$VENDOR_SRC/setup.py" ] && VENDOR_PRESENT=1

mkdir -p "$LOG_DIR"
: > "$SYSTEMCTL_LOG"
export SYSTEMCTL_STUB_LOG="$SYSTEMCTL_LOG"

PASS=0
FAIL=0
PHASE=""

phase() { PHASE="$*"; echo; echo "=== PHASE: $PHASE ==="; }
pass() { PASS=$((PASS+1)); echo "  PASS [$PHASE] $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL [$PHASE] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

assert_eq() { # actual expected description
  if [ "$1" = "$2" ]; then pass "$3 (got '$1')"
  else fail "$3 (expected '$2', got '$1')"; fi
}

assert_file_present() {
  if [ -f "$1" ]; then pass "$2"
  else fail "$2 (missing $1)"; fi
}

assert_grep() { # pattern file description
  if grep -qE "$1" "$2" 2>/dev/null; then pass "$3"
  else fail "$3 (pattern '$1' not in $2)"; fi
}

# ─────────────────────────────────────────────────────────────────────
phase "A — environment sanity"
# ─────────────────────────────────────────────────────────────────────
echo "  uname:       $(uname -a)"
echo "  os-release:  $(grep PRETTY_NAME /etc/os-release | cut -d= -f2)"
have node && pass "node available ($(node --version))" || fail "node missing"
have npm && pass "npm available ($(npm --version))" || fail "npm missing"
have curl && pass "curl available" || fail "curl missing"
have python3 && pass "python3 available ($(python3 --version 2>&1))" || fail "python3 missing"
have systemctl && pass "systemctl stub on PATH" || fail "systemctl stub missing"
[ -d "$ZIG_REPO" ] && pass "zig-awr-v3 repo mounted" || fail "zig-awr-v3 missing"
if [ "$DASH_PRESENT" = 1 ]; then pass "adeept-dashboard repo mounted"
else echo "  NOTE [$PHASE] adeept-dashboard not mounted; F/G phases will skip"; fi
if [ "$VENDOR_PRESENT" = 1 ]; then pass "adeept-vendor source mounted"
else echo "  NOTE [$PHASE] adeept-vendor not mounted; I/J/K/L/M phases will skip"; fi

# ─────────────────────────────────────────────────────────────────────
phase "B — install-pi.sh dry-run"
# ─────────────────────────────────────────────────────────────────────
DRY_LOG="$LOG_DIR/install-dry-run.log"
bash "$ZIG_REPO/scripts/install-pi.sh" \
  --user "$ACCEPTANCE_USER" \
  --prefix "$PREFIX" \
  --build-mode sim \
  --dry-run > "$DRY_LOG" 2>&1
assert_eq "$?" "0" "dry-run exits 0"

for marker in \
  "Step 1: install build dependencies" \
  "Step 2: ensure Zig" \
  "Step 3: stage repository" \
  "Step 4: ensure credentials env file" \
  "Step 5: install systemd unit" \
  "Step 6: install awr-stack helper" \
  "systemctl daemon-reload"; do
  assert_grep "$marker" "$DRY_LOG" "dry-run announces: $marker"
done

# ─────────────────────────────────────────────────────────────────────
phase "C — install-pi.sh real run"
# ─────────────────────────────────────────────────────────────────────
INSTALL_LOG="$LOG_DIR/install.log"
: > "$SYSTEMCTL_LOG"
bash "$ZIG_REPO/scripts/install-pi.sh" \
  --user "$ACCEPTANCE_USER" \
  --prefix "$PREFIX" \
  --build-mode sim > "$INSTALL_LOG" 2>&1
INSTALL_RC=$?
if [ "$INSTALL_RC" != "0" ]; then
  echo "  --- install.log (last 60 lines) ---"
  tail -60 "$INSTALL_LOG"
fi
assert_eq "$INSTALL_RC" "0" "install exits 0"

assert_file_present "$PREFIX/zig-out/bin/awr-v3" "binary built at $PREFIX/zig-out/bin/awr-v3"
assert_file_present "$PREFIX/build.zig" "repo staged at $PREFIX"
assert_file_present "$CRED_FILE" "credentials env file"
PERMS="$(stat -c '%a' "$CRED_FILE" 2>/dev/null || echo 0)"
assert_eq "$PERMS" "600" "credentials env is chmod 600"
assert_grep "AWR_WS_USER=admin" "$CRED_FILE" "credentials default user"
assert_grep "AWR_WS_PASS=123456" "$CRED_FILE" "credentials default pass"

assert_file_present "$SERVICE_FILE" "systemd unit installed"
assert_grep "ExecStart=$PREFIX/zig-out/bin/awr-v3" "$SERVICE_FILE" "service ExecStart"
assert_grep "EnvironmentFile=$CRED_FILE" "$SERVICE_FILE" "service EnvironmentFile"
assert_grep "WantedBy=multi-user.target" "$SERVICE_FILE" "service WantedBy multi-user"

if [ -x /usr/local/bin/awr-stack ]; then pass "awr-stack helper installed"; else fail "awr-stack missing"; fi
assert_grep "daemon-reload" "$SYSTEMCTL_LOG" "install ran systemctl daemon-reload"

# Service must NOT be enabled at install time — toggling is the user's call.
if grep -qE "(enable[^-d]|enable$|enable --now)" "$SYSTEMCTL_LOG"; then
  fail "install must not enable the service automatically"
else
  pass "install left service disabled (additive, no auto-enable)"
fi

# ─────────────────────────────────────────────────────────────────────
phase "D — Zig binary starts and serves WebSocket"
# ─────────────────────────────────────────────────────────────────────
export AWR_WS_USER=admin AWR_WS_PASS=123456
"$PREFIX/zig-out/bin/awr-v3" > "$LOG_DIR/binary.log" 2>&1 &
BIN_PID=$!
# Wait up to 5s for the listener
for _ in $(seq 1 20); do
  if (echo > /dev/tcp/127.0.0.1/8889) 2>/dev/null; then break; fi
  sleep 0.25
done
if kill -0 "$BIN_PID" 2>/dev/null && (echo > /dev/tcp/127.0.0.1/8889) 2>/dev/null; then
  pass "binary listening on :8889"
  PROTO_LOG="$LOG_DIR/zig-protocol.log"
  if WS_URL="ws://127.0.0.1:8889" INCLUDE_SLAM=1 BACKEND_LABEL=zig \
     node "$ZIG_REPO/scripts/acceptance/ws-protocol-test.mjs" > "$PROTO_LOG" 2>&1; then
    pass "ws-protocol-test (full SLAM) passed against Zig binary"
    cat "$PROTO_LOG" | tail -1 | sed 's/^/    summary: /'
  else
    fail "ws-protocol-test failed against Zig binary"
    echo "  --- ws-protocol-test (last 40 lines) ---"
    tail -40 "$PROTO_LOG"
  fi
else
  fail "binary did not start"
  echo "  --- binary.log (last 40 lines) ---"
  tail -40 "$LOG_DIR/binary.log"
fi
kill "$BIN_PID" 2>/dev/null || true
wait "$BIN_PID" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────
phase "E — awr-stack toggles vendor / Zig systemd units"
# ─────────────────────────────────────────────────────────────────────
: > "$SYSTEMCTL_LOG"
awr-stack zig > "$LOG_DIR/awr-stack-zig.log" 2>&1
assert_eq "$?" "0" "awr-stack zig exits 0"
assert_grep "stop Adeept_Robot.service" "$SYSTEMCTL_LOG" "awr-stack zig stops vendor"
assert_grep "disable Adeept_Robot.service" "$SYSTEMCTL_LOG" "awr-stack zig disables vendor"
assert_grep "enable.+--now.+awr-v3-zig.service" "$SYSTEMCTL_LOG" "awr-stack zig starts Zig"

: > "$SYSTEMCTL_LOG"
awr-stack python > "$LOG_DIR/awr-stack-python.log" 2>&1
assert_eq "$?" "0" "awr-stack python exits 0"
assert_grep "stop awr-v3-zig.service" "$SYSTEMCTL_LOG" "awr-stack python stops Zig"
assert_grep "disable awr-v3-zig.service" "$SYSTEMCTL_LOG" "awr-stack python disables Zig"
assert_grep "enable.+--now.+Adeept_Robot.service" "$SYSTEMCTL_LOG" "awr-stack python starts vendor"

: > "$SYSTEMCTL_LOG"
awr-stack stop > "$LOG_DIR/awr-stack-stop.log" 2>&1
assert_grep "stop Adeept_Robot.service" "$SYSTEMCTL_LOG" "awr-stack stop halts vendor"
assert_grep "stop awr-v3-zig.service" "$SYSTEMCTL_LOG" "awr-stack stop halts Zig"

awr-stack status > "$LOG_DIR/awr-stack-status.log" 2>&1
assert_grep "Adeept_Robot.service" "$LOG_DIR/awr-stack-status.log" "awr-stack status mentions vendor"
assert_grep "awr-v3-zig.service" "$LOG_DIR/awr-stack-status.log" "awr-stack status mentions Zig"

# ─────────────────────────────────────────────────────────────────────
phase "F — dashboard protocol tests against Node simulator"
# ─────────────────────────────────────────────────────────────────────
if [ "$DASH_PRESENT" = 1 ]; then
  ( cd "$DASH_REPO" && npm install --no-audit --no-fund > "$LOG_DIR/npm-install.log" 2>&1 ) \
    && pass "dashboard npm install" \
    || { fail "dashboard npm install"; tail -40 "$LOG_DIR/npm-install.log"; }

  if ( cd "$DASH_REPO" && npm run test:protocol > "$LOG_DIR/dashboard-test.log" 2>&1 ); then
    pass "dashboard test:protocol against Node simulator"
  else
    fail "dashboard test:protocol failed"
    tail -40 "$LOG_DIR/dashboard-test.log"
  fi
else
  echo "  SKIP [$PHASE] adeept-dashboard not mounted"
fi

# ─────────────────────────────────────────────────────────────────────
phase "G — dashboard ws-protocol-test against the Zig binary"
# (Cross-implementation parity: same generic test, Zig firmware in role of simulator.)
# ─────────────────────────────────────────────────────────────────────
"$PREFIX/zig-out/bin/awr-v3" > "$LOG_DIR/binary-2.log" 2>&1 &
BIN_PID=$!
for _ in $(seq 1 20); do
  if (echo > /dev/tcp/127.0.0.1/8889) 2>/dev/null; then break; fi
  sleep 0.25
done
if (echo > /dev/tcp/127.0.0.1/8889) 2>/dev/null; then
  if WS_URL="ws://127.0.0.1:8889" INCLUDE_SLAM=1 BACKEND_LABEL=zig \
     node "$ZIG_REPO/scripts/acceptance/ws-protocol-test.mjs" > "$LOG_DIR/zig-protocol-2.log" 2>&1; then
    pass "ws-protocol-test passes against Zig binary on second start"
  else
    fail "ws-protocol-test second pass failed"
    tail -40 "$LOG_DIR/zig-protocol-2.log"
  fi
else
  fail "binary did not restart"
fi
kill "$BIN_PID" 2>/dev/null || true
wait "$BIN_PID" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────
phase "H — Zig stack uninstall is clean"
# ─────────────────────────────────────────────────────────────────────
: > "$SYSTEMCTL_LOG"
bash "$ZIG_REPO/scripts/uninstall-pi.sh" > "$LOG_DIR/uninstall.log" 2>&1
assert_eq "$?" "0" "uninstall exits 0"
[ ! -d "$PREFIX" ] && pass "prefix removed" || fail "prefix still present"
[ ! -f "$SERVICE_FILE" ] && pass "service unit removed" || fail "service unit still present"
[ ! -f "$CRED_FILE" ] && pass "credentials removed" || fail "credentials still present"
assert_grep "stop awr-v3-zig.service" "$SYSTEMCTL_LOG" "uninstall stops Zig service"

# ─────────────────────────────────────────────────────────────────────
phase "I — vendor Adeept setup.py runs end-to-end"
# (proves the original install flow lands the systemd unit and
# startup.sh; apt + pip are pre-baked in the Dockerfile so the script
# logic itself is what's exercised here.)
# ─────────────────────────────────────────────────────────────────────
if [ "$VENDOR_PRESENT" = 1 ]; then
  rm -rf "$VENDOR_PREFIX"
  cp -r "$VENDOR_SRC" "$VENDOR_PREFIX"
  : > "$SYSTEMCTL_LOG"

  # Reinstall the Zig stack first so we are testing coexistence (the
  # whole point: vendor must install cleanly even when the Zig service
  # is already on the system).
  bash "$ZIG_REPO/scripts/install-pi.sh" \
    --user "$ACCEPTANCE_USER" \
    --prefix "$PREFIX" \
    --build-mode sim > "$LOG_DIR/install-zig-2.log" 2>&1
  assert_eq "$?" "0" "Zig install (round 2, before vendor) exits 0"

  bash "$ZIG_REPO/scripts/acceptance/run-vendor-setup.sh" "$VENDOR_PREFIX" \
    > "$LOG_DIR/vendor-setup.log" 2>&1
  RC=$?
  if [ "$RC" != 0 ]; then
    echo "  --- vendor-setup.log (last 30 lines) ---"
    tail -30 "$LOG_DIR/vendor-setup.log"
  fi
  assert_eq "$RC" "0" "vendor setup.py exits 0"

  assert_file_present "$VENDOR_SERVICE_FILE" "Adeept_Robot.service installed"
  assert_grep "ExecStart=$STARTUP_SH" "$VENDOR_SERVICE_FILE" "vendor ExecStart points at startup.sh"
  assert_grep "After=wifi-hotspot-manager.service" "$VENDOR_SERVICE_FILE" "vendor service After= chain"

  assert_file_present "$VENDOR_WIFI_SERVICE_FILE" "wifi-hotspot-manager.service installed"
  assert_file_present "$STARTUP_SH" "vendor startup.sh dropped at $STARTUP_SH"
  assert_grep "WebServer.py" "$STARTUP_SH" "startup.sh launches WebServer.py"

  assert_grep "daemon-reload" "$SYSTEMCTL_LOG" "vendor setup ran systemctl daemon-reload"
  assert_grep "enable Adeept_Robot.service" "$SYSTEMCTL_LOG" "vendor setup enables Adeept_Robot.service"

  # And the Zig service must still be intact — the vendor install is
  # additive; it must not delete or rewrite our unit.
  [ -f "$SERVICE_FILE" ] && pass "Zig service unit untouched by vendor install" \
    || fail "vendor install clobbered Zig service unit"

  # Both unit files exist on disk and reference different ports/binaries.
  assert_grep "8889" "$SERVICE_FILE" "Zig unit still references :8889"
  assert_grep "WebServer.py" "$STARTUP_SH" "vendor startup.sh still references WebServer.py"

else
  echo "  SKIP [$PHASE] vendor source not mounted"
fi

# ─────────────────────────────────────────────────────────────────────
phase "J — vendor WebServer.py boots and passes WS protocol test"
# ─────────────────────────────────────────────────────────────────────
if [ "$VENDOR_PRESENT" = 1 ]; then
  bash "$ZIG_REPO/scripts/acceptance/run-vendor-server.sh" \
    > "$LOG_DIR/vendor-server.log" 2>&1 &
  VENDOR_PID=$!
  for _ in $(seq 1 40); do
    if (echo > /dev/tcp/127.0.0.1/8888) 2>/dev/null; then break; fi
    sleep 0.25
  done
  if kill -0 "$VENDOR_PID" 2>/dev/null && (echo > /dev/tcp/127.0.0.1/8888) 2>/dev/null; then
    pass "vendor WebServer.py listening on :8888"
    if WS_URL="ws://127.0.0.1:8888" BACKEND_LABEL=vendor \
       node "$ZIG_REPO/scripts/acceptance/ws-protocol-test.mjs" \
       > "$LOG_DIR/vendor-protocol.log" 2>&1; then
      pass "ws-protocol-test (subset) passed against vendor Python"
      cat "$LOG_DIR/vendor-protocol.log" | tail -1 | sed 's/^/    summary: /'
    else
      fail "ws-protocol-test failed against vendor Python"
      tail -40 "$LOG_DIR/vendor-protocol.log"
    fi
  else
    fail "vendor WebServer.py did not bind :8888"
    echo "  --- vendor-server.log (last 40 lines) ---"
    tail -40 "$LOG_DIR/vendor-server.log"
  fi
  kill "$VENDOR_PID" 2>/dev/null || true
  wait "$VENDOR_PID" 2>/dev/null || true
else
  echo "  SKIP [$PHASE] vendor source not mounted"
fi

# ─────────────────────────────────────────────────────────────────────
phase "K — dual-stack live: vendor :8888 + Zig :8889 simultaneously"
# Empirical evidence the two stacks can coexist without GPIO/I2C
# conflict (different ports, different processes, different memory).
# ─────────────────────────────────────────────────────────────────────
if [ "$VENDOR_PRESENT" = 1 ]; then
  bash "$ZIG_REPO/scripts/acceptance/run-vendor-server.sh" > "$LOG_DIR/vendor-server-2.log" 2>&1 &
  VENDOR_PID=$!
  "$PREFIX/zig-out/bin/awr-v3" > "$LOG_DIR/binary-3.log" 2>&1 &
  ZIG_PID=$!

  # Wait for both ports
  V_OK=0; Z_OK=0
  for _ in $(seq 1 40); do
    [ "$V_OK" = 0 ] && (echo > /dev/tcp/127.0.0.1/8888) 2>/dev/null && V_OK=1
    [ "$Z_OK" = 0 ] && (echo > /dev/tcp/127.0.0.1/8889) 2>/dev/null && Z_OK=1
    [ "$V_OK" = 1 ] && [ "$Z_OK" = 1 ] && break
    sleep 0.25
  done
  [ "$V_OK" = 1 ] && pass "vendor Python listening on :8888 (concurrent)" || fail "vendor :8888 not listening"
  [ "$Z_OK" = 1 ] && pass "Zig firmware listening on :8889 (concurrent)" || fail "Zig :8889 not listening"

  if [ "$V_OK" = 1 ] && [ "$Z_OK" = 1 ]; then
    if WS_URL="ws://127.0.0.1:8888" BACKEND_LABEL=vendor-dual \
         node "$ZIG_REPO/scripts/acceptance/ws-protocol-test.mjs" >"$LOG_DIR/dual-vendor.log" 2>&1; then
      pass "vendor protocol test under dual-stack"
    else
      fail "vendor protocol test failed under dual-stack"
      tail -20 "$LOG_DIR/dual-vendor.log"
    fi
    if WS_URL="ws://127.0.0.1:8889" INCLUDE_SLAM=1 BACKEND_LABEL=zig-dual \
         node "$ZIG_REPO/scripts/acceptance/ws-protocol-test.mjs" >"$LOG_DIR/dual-zig.log" 2>&1; then
      pass "Zig SLAM protocol test under dual-stack"
    else
      fail "Zig protocol test failed under dual-stack"
      tail -20 "$LOG_DIR/dual-zig.log"
    fi
  fi

  kill "$VENDOR_PID" 2>/dev/null || true
  kill "$ZIG_PID" 2>/dev/null || true
  wait "$VENDOR_PID" 2>/dev/null || true
  wait "$ZIG_PID" 2>/dev/null || true
else
  echo "  SKIP [$PHASE] vendor source not mounted"
fi

# ─────────────────────────────────────────────────────────────────────
phase "L — awr-stack toggles cleanly with both stacks installed"
# ─────────────────────────────────────────────────────────────────────
if [ "$VENDOR_PRESENT" = 1 ]; then
  : > "$SYSTEMCTL_LOG"
  awr-stack zig > "$LOG_DIR/awr-stack-zig-dual.log" 2>&1
  assert_eq "$?" "0" "awr-stack zig exits 0 (dual-stack)"
  assert_grep "stop Adeept_Robot.service" "$SYSTEMCTL_LOG" "awr-stack zig stops vendor"
  assert_grep "enable.+--now.+awr-v3-zig.service" "$SYSTEMCTL_LOG" "awr-stack zig starts Zig"

  : > "$SYSTEMCTL_LOG"
  awr-stack python > "$LOG_DIR/awr-stack-python-dual.log" 2>&1
  assert_eq "$?" "0" "awr-stack python exits 0 (dual-stack)"
  assert_grep "stop awr-v3-zig.service" "$SYSTEMCTL_LOG" "awr-stack python stops Zig"
  assert_grep "enable.+--now.+Adeept_Robot.service" "$SYSTEMCTL_LOG" "awr-stack python starts vendor"

  : > "$SYSTEMCTL_LOG"
  awr-stack both > "$LOG_DIR/awr-stack-both-dual.log" 2>&1
  assert_grep "Adeept_Robot.service" "$SYSTEMCTL_LOG" "awr-stack both touches vendor"
  assert_grep "awr-v3-zig.service" "$SYSTEMCTL_LOG" "awr-stack both touches Zig"

  : > "$SYSTEMCTL_LOG"
  awr-stack stop > "$LOG_DIR/awr-stack-stop-dual.log" 2>&1
  assert_grep "stop Adeept_Robot.service" "$SYSTEMCTL_LOG" "awr-stack stop halts vendor"
  assert_grep "stop awr-v3-zig.service" "$SYSTEMCTL_LOG" "awr-stack stop halts Zig"
else
  echo "  SKIP [$PHASE] vendor source not mounted"
fi

# ─────────────────────────────────────────────────────────────────────
phase "M — full uninstall: both stacks gone, system clean"
# ─────────────────────────────────────────────────────────────────────
if [ "$VENDOR_PRESENT" = 1 ]; then
  : > "$SYSTEMCTL_LOG"
  bash "$ZIG_REPO/scripts/uninstall-pi.sh" > "$LOG_DIR/uninstall-zig-final.log" 2>&1
  assert_eq "$?" "0" "Zig uninstall exits 0 (round 2)"

  # Vendor uninstall: there is no vendor uninstall script, so we do
  # the equivalent cleanup by hand and verify the result. This is
  # what an operator would do when retiring the Adeept stack.
  rm -rf "$VENDOR_PREFIX" "$STARTUP_SH" "$VENDOR_SERVICE_FILE" "$VENDOR_WIFI_SERVICE_FILE"
  systemctl daemon-reload || true

  [ ! -f "$VENDOR_SERVICE_FILE" ] && pass "vendor service unit removed" || fail "vendor service unit still present"
  [ ! -f "$VENDOR_WIFI_SERVICE_FILE" ] && pass "wifi service unit removed" || fail "wifi service unit still present"
  [ ! -f "$STARTUP_SH" ] && pass "vendor startup.sh removed" || fail "vendor startup.sh still present"
  [ ! -f "$SERVICE_FILE" ] && pass "Zig unit removed" || fail "Zig unit still present"
  [ ! -d "$PREFIX" ] && pass "Zig prefix removed" || fail "Zig prefix still present"
  assert_grep "stop awr-v3-zig.service" "$SYSTEMCTL_LOG" "Zig uninstall (final) stops the service"
else
  echo "  SKIP [$PHASE] vendor source not mounted"
fi

# ─────────────────────────────────────────────────────────────────────
phase "N — in-situ-test.sh script logic (rehearsal pass)"
# This validates scripts/in-situ-test.sh — the orchestrator we ship for
# the on-Pi acceptance run — by executing it in rehearsal mode (auto-
# detected via /.dockerenv). It re-installs the Zig stack from a clean
# state, exercises awr-stack via the systemctl stub, boots the Zig
# binary, boots the vendor WebServer.py via run-vendor-server.sh,
# proves dual-stack live in this container, and ends by restoring the
# snapshotted (empty) state. If anything in the script regresses, we
# catch it here before pushing to a Pi.
# ─────────────────────────────────────────────────────────────────────
INSITU_LOG="$LOG_DIR/in-situ-rehearsal.log"
INSITU_REPO="/opt/test/zig-awr-v3"
INSITU_VENDOR="/opt/Adeept_AWR-V3"
# Phase M removed VENDOR_PREFIX. Re-stage the vendor source so the
# in-situ script's vendor-side phases can run.
if [ "$VENDOR_PRESENT" = 1 ] && [ ! -d "$INSITU_VENDOR" ]; then
  cp -r "$VENDOR_SRC" "$INSITU_VENDOR"
fi

set +e
SYSTEMCTL_STUB_LOG="$SYSTEMCTL_LOG" \
  bash "$INSITU_REPO/scripts/in-situ-test.sh" \
    --user "$ACCEPTANCE_USER" \
    --vendor-dir "$INSITU_VENDOR" \
    --rehearsal \
    --keep-current \
    > "$INSITU_LOG" 2>&1
INSITU_RC=$?
set -e

# Forward in-situ tallies into the outer summary so the orchestrator's
# final PASS/FAIL count reflects every assertion, not just "did it
# exit 0". This is critical: if the in-situ script soft-fails on a
# single assertion but exits 0 by accident, we still see it here.
INSITU_PASS=$(grep -c "^  PASS " "$INSITU_LOG" || true)
INSITU_FAIL=$(grep -c "^  FAIL " "$INSITU_LOG" || true)
PASS=$((PASS + INSITU_PASS))
FAIL=$((FAIL + INSITU_FAIL))
echo "  in-situ-test.sh tallied: PASS=$INSITU_PASS, FAIL=$INSITU_FAIL"
if [ "$INSITU_RC" = 0 ] && [ "$INSITU_FAIL" = 0 ]; then
  echo "  PASS [$PHASE] in-situ-test.sh --rehearsal exits 0 with FAIL=0"
  PASS=$((PASS+1))
else
  echo "  FAIL [$PHASE] in-situ-test.sh exited $INSITU_RC with FAIL=$INSITU_FAIL"
  FAIL=$((FAIL+1))
  echo "  --- last 60 lines of in-situ rehearsal log ---"
  tail -60 "$INSITU_LOG" | sed 's/^/    /'
fi

# Verify the in-situ runner's final summary line exists.
if grep -q "=== IN-SITU SUMMARY ===" "$INSITU_LOG"; then
  echo "  PASS [$PHASE] in-situ runner emitted final summary block"
  PASS=$((PASS+1))
else
  echo "  FAIL [$PHASE] in-situ runner did not emit summary block"
  FAIL=$((FAIL+1))
fi

# ─────────────────────────────────────────────────────────────────────
echo
echo "=== ACCEPTANCE SUMMARY ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
