#!/usr/bin/env bash
# Functional acceptance orchestrator — runs inside the Docker image.
# Exits non-zero if any phase fails. Designed to be black-box: we do
# not import from the implementation; we exercise it via the same
# entry points (install-pi.sh, the compiled binary, awr-stack, the
# dashboard's npm scripts).

set -uo pipefail

ZIG_REPO="/opt/test/zig-awr-v3"
DASH_REPO="/opt/test/adeept-dashboard"
LOG_DIR="/tmp/acceptance-logs"
SYSTEMCTL_LOG="/var/log/stub-systemctl.log"
PREFIX="/opt/awr-v3-zig"
SERVICE_FILE="/etc/systemd/system/awr-v3-zig.service"
CRED_FILE="/etc/awr-v3-zig/credentials.env"

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
have systemctl && pass "systemctl stub on PATH" || fail "systemctl stub missing"
[ -d "$ZIG_REPO" ] && pass "zig-awr-v3 repo mounted" || fail "zig-awr-v3 missing"
[ -d "$DASH_REPO" ] && pass "adeept-dashboard repo mounted" \
  || echo "  NOTE [$PHASE] adeept-dashboard not mounted; dashboard phases will skip"

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
  if WS_URL="ws://127.0.0.1:8889" \
     node "$ZIG_REPO/scripts/acceptance/ws-protocol-test.mjs" > "$PROTO_LOG" 2>&1; then
    pass "ws-protocol-test passed against Zig binary"
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
if [ -d "$DASH_REPO" ]; then
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
  if WS_URL="ws://127.0.0.1:8889" \
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
phase "H — uninstall is clean"
# ─────────────────────────────────────────────────────────────────────
: > "$SYSTEMCTL_LOG"
bash "$ZIG_REPO/scripts/uninstall-pi.sh" > "$LOG_DIR/uninstall.log" 2>&1
assert_eq "$?" "0" "uninstall exits 0"
[ ! -d "$PREFIX" ] && pass "prefix removed" || fail "prefix still present"
[ ! -f "$SERVICE_FILE" ] && pass "service unit removed" || fail "service unit still present"
[ ! -f "$CRED_FILE" ] && pass "credentials removed" || fail "credentials still present"
assert_grep "stop awr-v3-zig.service" "$SYSTEMCTL_LOG" "uninstall stops Zig service"

# ─────────────────────────────────────────────────────────────────────
echo
echo "=== ACCEPTANCE SUMMARY ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
