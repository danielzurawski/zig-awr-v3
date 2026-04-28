#!/usr/bin/env bash
# Run the vendor `setup.py` from the acceptance container. The
# original script does three destructive things that don't make sense
# inside Docker:
#
#   1. `apt-get purge wolfram-engine, libreoffice*` (we never installed
#      either; the purge fails harmlessly but the loop retries 3x)
#   2. `pip install` huge wheels (numpy/pyzmq/imutils etc) we already
#      pre-installed in the Dockerfile; they'd just refetch the index
#   3. `sudo reboot` at the end (would kill the container immediately)
#
# We patch a temporary copy that:
#   - replaces every command-list with no-ops (apt + pip pre-baked)
#   - strips the trailing `sudo reboot`
# everything else (the systemd unit/file writes, daemon-reload, etc.)
# runs verbatim against the stubbed systemctl, which is exactly what
# we want to assert against.
#
# Usage: run-vendor-setup.sh <vendor_src_dir>

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <vendor_src_dir>" >&2
  exit 1
fi

VENDOR_SRC="$1"
TEST_USER="${ACCEPTANCE_USER:-root}"

if [ ! -f "$VENDOR_SRC/setup.py" ]; then
  echo "[vendor-setup] $VENDOR_SRC/setup.py missing" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$VENDOR_SRC/." "$WORK/"

# Patch: skip apt + pip + reboot, keep systemd plumbing.
python3 - <<'PY' "$WORK/setup.py"
import re
import sys
path = sys.argv[1]
src = open(path).read()

# Empty out the apt and pip command lists.
src = re.sub(r'commands_apt\s*=\s*\[[^\]]*\]', 'commands_apt = []', src, count=1, flags=re.DOTALL)
src = re.sub(r'commands_pip_1\s*=\s*\[[^\]]*\]', 'commands_pip_1 = []', src, count=1, flags=re.DOTALL)
src = re.sub(r'commands_pip_2\s*=\s*\[[^\]]*\]', 'commands_pip_2 = []', src, count=1, flags=re.DOTALL)

# Skip the trailing reboot.
src = src.replace('os.system("sudo reboot")', '# acceptance: reboot skipped')

# Provide an empty wifi helper script so the cp succeeds in the
# wifi-hotspot-manager.service branch.
extra = "import os, pathlib\n" \
        "wifi_helper = pathlib.Path(__file__).resolve().parent / 'wifi_hotspot_manager.sh'\n" \
        "if not wifi_helper.exists(): wifi_helper.write_text('#!/bin/sh\\nexit 0\\n')\n" \
        "os.chmod(str(wifi_helper), 0o755)\n"
src = src.replace('curpath = os.path.realpath(__file__)', extra + 'curpath = os.path.realpath(__file__)')

open(path, 'w').write(src)
print(f"[vendor-setup] patched {path}", file=sys.stderr)
PY

echo "[vendor-setup] running patched setup.py from $WORK"
sudo -E SUDO_USER="$TEST_USER" python3 "$WORK/setup.py"
