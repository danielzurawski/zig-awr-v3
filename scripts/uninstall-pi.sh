#!/usr/bin/env bash
# Adeept AWR-V3 Zig firmware — Pi uninstaller.
# Removes the systemd unit, prefix dir, helper, and credentials env file.
# Does NOT touch the vendor Adeept_Robot.service or its files.
set -euo pipefail

PREFIX="/opt/awr-v3-zig"
ENV_FILE="/etc/awr-v3-zig/credentials.env"
ENV_DIR="/etc/awr-v3-zig"
SERVICE_NAME="awr-v3-zig.service"

if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICE_NAME"
systemctl daemon-reload

rm -rf "$PREFIX"
rm -f "$ENV_FILE"
rmdir "$ENV_DIR" 2>/dev/null || true
rm -f /usr/local/bin/awr-stack

echo "[uninstall] Zig firmware removed. Vendor stack untouched."
