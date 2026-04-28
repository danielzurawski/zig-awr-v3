#!/usr/bin/env bash
# Start the vendor Adeept Python WebServer.py inside the acceptance
# container. Uses the docker/vendor_stubs/ directory to replace the
# hardware-touching modules (Move, RPIservo, board, busio, ...) so
# the *real* protocol code in WebServer.py boots without a Pi HAT.
#
#   VENDOR_PREFIX  -- where vendor was installed (default /opt/Adeept_AWR-V3)
#   VENDOR_PORT    -- WS port (default 8888)
#   STUB_DIR       -- replacement stubs (default $ZIG_REPO/docker/vendor_stubs)

set -euo pipefail

VENDOR_PREFIX="${VENDOR_PREFIX:-/opt/Adeept_AWR-V3}"
VENDOR_PORT="${VENDOR_PORT:-8888}"
STUB_DIR="${STUB_DIR:-/opt/test/zig-awr-v3/docker/vendor_stubs}"

if [ ! -d "$VENDOR_PREFIX/Server" ]; then
  echo "[vendor] Server dir not found at $VENDOR_PREFIX/Server" >&2
  exit 1
fi

if [ ! -d "$STUB_DIR" ]; then
  echo "[vendor] stubs dir $STUB_DIR not found" >&2
  exit 1
fi

# Stubs first, then vendor Server modules. Local project modules
# (Move, RPIservo, …) live in Server/, so vendor imports resolve to
# our stubs first because STUB_DIR comes before Server/ on PYTHONPATH.
export PYTHONPATH="$STUB_DIR:$VENDOR_PREFIX/Server:${PYTHONPATH:-}"

# CRITICAL: -P prevents Python from prepending the script's directory
# to sys.path[0] (which would otherwise win over PYTHONPATH and cause
# `import Move` to find the real hardware-touching vendor module
# instead of our stub). -P needs Python 3.11+ which Bookworm ships.
cd "$VENDOR_PREFIX/Server"
exec python3 -P -u WebServer.py
