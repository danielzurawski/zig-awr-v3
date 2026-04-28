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

USAGE="Usage: $0 [--user USER] [--prefix PATH] [--zig-version 0.14.1] [--dry-run]"
TARGET_USER="${SUDO_USER:-${USER}}"
PREFIX="/opt/awr-v3-zig"
ZIG_VERSION="0.14.1"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --zig-version) ZIG_VERSION="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) echo "$USAGE"; exit 0;;
    *) echo "Unknown arg: $1"; echo "$USAGE"; exit 1;;
  esac
done

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
  exec sudo "$0" --user "$TARGET_USER" --prefix "$PREFIX" --zig-version "$ZIG_VERSION"
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
run "apt-get install -y build-essential curl tar xz-utils i2c-tools ca-certificates"

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
  URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZARCH}-${ZIG_VERSION}.tar.xz"
  note "Downloading $URL"
  run "mkdir -p /opt"
  run "curl -fsSL $URL | tar -xJ -C /opt"
  run "ln -sf /opt/zig-linux-${ZARCH}-${ZIG_VERSION}/zig /usr/local/bin/zig"
fi

note "Step 3: stage repository at $PREFIX and build"
run "mkdir -p $PREFIX"
run "cp -r $REPO_ROOT/. $PREFIX/"
run "chown -R $TARGET_USER $PREFIX"
run "su - $TARGET_USER -c 'cd $PREFIX && /usr/local/bin/zig build -Doptimize=ReleaseSafe -Dsim=false'"

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
