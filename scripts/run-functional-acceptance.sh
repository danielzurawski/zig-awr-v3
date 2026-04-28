#!/usr/bin/env bash
# Build and run the AWR-V3 functional acceptance container.
#
# Requirements:
#   - Docker (with buildx; tested with Docker Desktop 27.x)
#   - The host can run linux/arm64 images. On Apple Silicon this is
#     native; on x86 it falls back to QEMU emulation (slower).
#   - This repo (zig-awr-v3) and adeept-dashboard sit as siblings, e.g.
#     ~/git/zig-awr-v3 and ~/git/adeept-dashboard. Adeept's vendor V3
#     source can be supplied via $VENDOR_SRC, or auto-detected from
#     ~/Downloads/Adeept_AWR-V3-*/Code/Adeept_AWR-V3.
#
# The orchestrator inside the container runs:
#   A. environment sanity                                  (no Pi)
#   B. install-pi.sh --dry-run                              (Zig)
#   C. install-pi.sh --build-mode sim                       (Zig)
#   D. compiled Zig binary + WS protocol test (full SLAM)   (Zig)
#   E. awr-stack {zig|python|stop|status} via systemctl stub
#   F. dashboard `npm run test:protocol`                    (Dashboard ↔ Node sim)
#   G. ws-protocol-test against the Zig binary (parity)     (Zig)
#   H. uninstall-pi.sh leaves the system clean              (Zig)
#   I. vendor setup.py runs                                  (Vendor Python)
#   J. vendor WebServer.py boots and passes WS protocol test (Vendor Python)
#   K. dual-stack live: vendor :8888 + Zig :8889 simultaneously
#   L. awr-stack toggles cleanly with both stacks installed
#   M. vendor uninstall + Zig uninstall: system fully clean

set -euo pipefail

ZIG_DIR="$(cd "$(dirname "$0")/.."; pwd)"
PARENT_DIR="$(cd "$ZIG_DIR/.."; pwd)"

PLATFORM="${PLATFORM:-linux/arm64}"
BASE_IMAGE="${BASE_IMAGE:-dtcooper/raspberrypi-os:bookworm}"
IMAGE_TAG="${IMAGE_TAG:-awr-v3-acceptance}"

# Auto-detect the vendor V3 source unless explicitly provided.
if [ -z "${VENDOR_SRC:-}" ]; then
  for cand in "$PARENT_DIR/Adeept_AWR-V3" \
              "$HOME/Downloads"/Adeept_AWR-V3-*/Code/Adeept_AWR-V3 \
              "$HOME/Adeept_AWR-V3"; do
    if [ -f "$cand/setup.py" ]; then
      VENDOR_SRC="$cand"; break
    fi
  done
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[acceptance] Docker not found on PATH. Install Docker Desktop or docker-engine." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "[acceptance] Docker daemon is not running. Start Docker Desktop and retry." >&2
  exit 1
fi

if [ ! -d "$PARENT_DIR/zig-awr-v3" ]; then
  echo "[acceptance] Expected $PARENT_DIR/zig-awr-v3 to exist." >&2
  exit 1
fi

# Stage a fresh build context that pulls together both repos AND
# (optionally) the vendor V3 source. Placeholders avoid Dockerfile
# COPY failures when something is missing and keep the orchestrator
# in charge of phase skipping.
STAGE="$(mktemp -d -t awr-v3-acceptance.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$PARENT_DIR/zig-awr-v3" "$STAGE/zig-awr-v3"

if [ -d "$PARENT_DIR/adeept-dashboard" ]; then
  cp -R "$PARENT_DIR/adeept-dashboard" "$STAGE/adeept-dashboard"
else
  mkdir -p "$STAGE/adeept-dashboard"
  : > "$STAGE/adeept-dashboard/.acceptance-placeholder"
  echo "[acceptance] Note: adeept-dashboard missing; F/G phases will skip."
fi

if [ -n "${VENDOR_SRC:-}" ] && [ -f "$VENDOR_SRC/setup.py" ]; then
  echo "[acceptance] Vendor V3 source: $VENDOR_SRC"
  cp -R "$VENDOR_SRC" "$STAGE/adeept-vendor"
else
  mkdir -p "$STAGE/adeept-vendor"
  : > "$STAGE/adeept-vendor/.acceptance-placeholder"
  echo "[acceptance] Note: vendor V3 source missing (set VENDOR_SRC=...);"
  echo "             I/J/K/L/M phases will skip vendor-side checks."
fi

echo "[acceptance] Build context : $STAGE"
echo "[acceptance] Platform      : $PLATFORM"
echo "[acceptance] Base image    : $BASE_IMAGE"
echo "[acceptance] Image tag     : $IMAGE_TAG"

DOCKER_BUILDKIT=1 docker build \
  --platform "$PLATFORM" \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  -f "$STAGE/zig-awr-v3/docker/Dockerfile.acceptance" \
  -t "$IMAGE_TAG" \
  "$STAGE"

echo
echo "[acceptance] Running tests inside the container..."
docker run --rm \
  --platform "$PLATFORM" \
  --name awr-v3-acceptance-run \
  "$IMAGE_TAG"
