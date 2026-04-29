#!/usr/bin/env bash
# Adeept AWR-V3 Zig firmware — one-shot Raspberry Pi installer.
#
# This is the Zig/Dashboard equivalent of the vendor `setup.py`:
# it installs the Zig toolchain, builds the firmware, registers a
# systemd service (DISABLED by default), and drops in the
# `awr-stack` helper that toggles between this stack and the
# original Adeept Python stack.
#
# Usage:
#   curl -fsSL <repo>/scripts/install-pi.sh | sudo bash
#   ./scripts/install-pi.sh [--user pi] [--prefix /opt/awr-v3-zig] [--dry-run]
#
# This script intentionally does NOT touch the vendor
# `Adeept_Robot.service`. Run `sudo python3 setup.py` from the
# Adeept zip first if you also want the vendor stack installed.

set -euo pipefail

USAGE="Usage: $0 [--user USER] [--prefix PATH] [--zig-version 0.14.1] [--node-major 22] [--build-mode real|sim] [--no-test-tools] [--dry-run]"
# Default user: SUDO_USER (when invoked via sudo on a real Pi), else $USER,
# else `root` so the script still parses arguments under `set -u` in
# minimal environments such as Docker containers without USER set.
TARGET_USER="${SUDO_USER:-${USER:-root}}"
PREFIX="/opt/awr-v3-zig"
ZIG_VERSION="0.14.1"
NODE_MAJOR="22"
BUILD_MODE="real"
DRY_RUN=0
INSTALL_TEST_TOOLS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --zig-version) ZIG_VERSION="$2"; shift 2;;
    --node-major) NODE_MAJOR="$2"; shift 2;;
    --build-mode) BUILD_MODE="$2"; shift 2;;
    --no-test-tools) INSTALL_TEST_TOOLS=0; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) echo "$USAGE"; exit 0;;
    *) echo "Unknown arg: $1"; echo "$USAGE"; exit 1;;
  esac
done

case "$BUILD_MODE" in
  real|sim) ;;
  *) echo "Invalid --build-mode: $BUILD_MODE (real|sim)"; exit 1;;
esac

note() { echo "[install] $*"; }
run() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "+ $*"
  else
    eval "$@"
  fi
}

if [ "$DRY_RUN" = 0 ] && [ "$EUID" -ne 0 ]; then
  note "Re-running with sudo..."
  SUDO_ARGS=( --user "$TARGET_USER" --prefix "$PREFIX" --zig-version "$ZIG_VERSION" --node-major "$NODE_MAJOR" --build-mode "$BUILD_MODE" )
  [ "$INSTALL_TEST_TOOLS" = 0 ] && SUDO_ARGS+=( --no-test-tools )
  exec sudo "$0" "${SUDO_ARGS[@]}"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.."; pwd)"
SERVICE_NAME="awr-v3-zig.service"
ENV_FILE="/etc/awr-v3-zig/credentials.env"

if ! [ -f "$REPO_ROOT/build.zig" ]; then
  note "build.zig not found in $REPO_ROOT — clone the repo first."
  exit 1
fi

note "Repository: $REPO_ROOT"
note "Install prefix: $PREFIX"
note "Target user: $TARGET_USER"
note "Zig version: $ZIG_VERSION"

if grep -q "Raspberry Pi" /sys/firmware/devicetree/base/model 2>/dev/null; then
  note "Detected: Raspberry Pi"
else
  note "Not a Raspberry Pi — proceeding for dev/test on this host."
fi

note "Step 1: install build dependencies"
run "apt-get update -y"
run "apt-get install -y build-essential curl tar xz-utils i2c-tools ca-certificates gnupg"

# Step 1b — Node.js. The in-situ acceptance runner and the dashboard
# Playwright suite both shell out to `node` (built-in WebSocket lands in
# Node 22) and `npm`. Pi OS Bookworm ships Node 18, which is too old.
# We pin the major (default 22) and pull from NodeSource. Skip with
# --no-test-tools if you don't need the acceptance / dashboard tooling.
if [ "$INSTALL_TEST_TOOLS" = 1 ]; then
  note "Step 1b: ensure Node.js $NODE_MAJOR.x + npm are installed"
  need_node=1
  if command -v node >/dev/null 2>&1; then
    if node --version | grep -qE "^v(${NODE_MAJOR}|$((NODE_MAJOR+1))|$((NODE_MAJOR+2))|$((NODE_MAJOR+3))|$((NODE_MAJOR+4)))\."; then
      need_node=0
      note "node $(node --version) already present, leaving alone"
    fi
  fi
  if [ "$need_node" = 1 ]; then
    run "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -"
    run "apt-get install -y --no-install-recommends nodejs"
  fi
else
  note "Step 1b: skipping Node.js (--no-test-tools); ws-protocol-test and Playwright will be unavailable"
fi

note "Step 2: ensure Zig $ZIG_VERSION is installed"
need_zig=1
if command -v zig >/dev/null 2>&1; then
  if zig version | grep -q "^${ZIG_VERSION%.*}\."; then need_zig=0; fi
fi
if [ "$need_zig" = 1 ]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    aarch64|arm64) ZARCH="aarch64";;
    armv7l|armv6l) ZARCH="armv7a";;
    x86_64) ZARCH="x86_64";;
    *) note "Unsupported arch for prebuilt Zig: $ARCH"; exit 1;;
  esac
  # Zig 0.14.x reorganised official tarballs: the order is now arch-os.
  # Probe both layouts so this script works with 0.13 and 0.14 releases.
  URL_NEW="https://ziglang.org/download/${ZIG_VERSION}/zig-${ZARCH}-linux-${ZIG_VERSION}.tar.xz"
  URL_OLD="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZARCH}-${ZIG_VERSION}.tar.xz"
  if curl -fsI "$URL_NEW" >/dev/null 2>&1; then
    URL="$URL_NEW"
    DIR_NAME="zig-${ZARCH}-linux-${ZIG_VERSION}"
  else
    URL="$URL_OLD"
    DIR_NAME="zig-linux-${ZARCH}-${ZIG_VERSION}"
  fi
  note "Downloading $URL"
  run "mkdir -p /opt"
  run "curl -fsSL $URL | tar -xJ -C /opt"
  run "ln -sf /opt/${DIR_NAME}/zig /usr/local/bin/zig"
fi

note "Step 3: stage repository at $PREFIX and build (mode=$BUILD_MODE)"
run "mkdir -p $PREFIX"
run "cp -r $REPO_ROOT/. $PREFIX/"
run "chown -R $TARGET_USER $PREFIX"
if [ "$BUILD_MODE" = "sim" ]; then
  ZIG_FLAGS="-Doptimize=ReleaseSafe -Dsim=true"
else
  ZIG_FLAGS="-Doptimize=ReleaseSafe -Dsim=false"
fi
run "su - $TARGET_USER -c 'cd $PREFIX && /usr/local/bin/zig build $ZIG_FLAGS'"

note "Step 4: ensure credentials env file exists"
run "mkdir -p $(dirname "$ENV_FILE")"
if ! [ -f "$ENV_FILE" ]; then
  run "tee $ENV_FILE >/dev/null <<EOF
# Adeept AWR-V3 Zig firmware credentials.
# These match the vendor stack defaults so the dashboard can use
# admin:123456 against either backend. Change here, then restart
# awr-v3-zig.service for the new credentials to take effect.
AWR_WS_USER=admin
AWR_WS_PASS=123456
EOF"
  run "chmod 600 $ENV_FILE"
  run "chown root:root $ENV_FILE"
else
  note "Credentials env file already exists; leaving alone."
fi

note "Step 5: install systemd unit (disabled by default)"
run "tee /etc/systemd/system/$SERVICE_NAME >/dev/null <<EOF
[Unit]
Description=Adeept AWR-V3 Zig firmware (WebSocket on :8889)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$PREFIX/zig-out/bin/awr-v3
Restart=on-failure
User=root
WorkingDirectory=$PREFIX

[Install]
WantedBy=multi-user.target
EOF"
run "systemctl daemon-reload"

note "Step 6: install awr-stack helper"
run "install -m 0755 $REPO_ROOT/scripts/awr-stack /usr/local/bin/awr-stack"

cat <<EOF

[install] Done.

Next steps:
  awr-stack status        # see both services
  awr-stack zig           # switch to Zig firmware (stops Python)
  awr-stack python        # switch back to vendor Python
  awr-stack stop          # stop everything (manual control)

The vendor Adeept_Robot.service was left untouched. Both services
share GPIO/I2C, so only run one at a time on real hardware.

Connect the dashboard to:
  - Zig firmware:   ws://raspberry-pi.local:8889  (admin:123456)
  - Vendor Python:  ws://raspberry-pi.local:8888  (admin:123456)
EOF
