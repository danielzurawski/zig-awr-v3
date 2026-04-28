#!/usr/bin/env bash
# Build and run the AWR-V3 functional acceptance container.
#
# Requirements:
#   - Docker (with buildx; tested with Docker Desktop 27.x)
#   - The host can run linux/arm64 images. On Apple Silicon this is
#     native; on x86 it falls back to QEMU emulation (slower).
#   - This repo (zig-awr-v3) and adeept-dashboard sit as siblings, e.g.
#     ~/git/zig-awr-v3 and ~/git/adeept-dashboard.
#
# The orchestrator inside the container runs:
#   A. environment sanity
#   B. install-pi.sh --dry-run, asserts every step is announced
#   C. install-pi.sh --build-mode sim (real run, stubbed systemctl)
#   D. starts the compiled binary, runs WS protocol acceptance test
#   E. exercises awr-stack {zig|python|stop|status} via the systemctl stub
#   F. dashboard `npm run test:protocol` against the Node simulator
#   G. dashboard ws-protocol-test against the Zig binary (cross-impl parity)
#   H. uninstall-pi.sh leaves the system clean

set -euo pipefail

ZIG_DIR="$(cd "$(dirname "$0")/.."; pwd)"
PARENT_DIR="$(cd "$ZIG_DIR/.."; pwd)"

PLATFORM="${PLATFORM:-linux/arm64}"
BASE_IMAGE="${BASE_IMAGE:-dtcooper/raspberrypi-os:bookworm}"
IMAGE_TAG="${IMAGE_TAG:-awr-v3-acceptance}"

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

if [ ! -d "$PARENT_DIR/adeept-dashboard" ]; then
  echo "[acceptance] Note: adeept-dashboard is missing as a sibling of zig-awr-v3."
  echo "[acceptance] Dashboard phases (F, G) will skip themselves. Continuing."
fi

echo "[acceptance] Build context : $PARENT_DIR"
echo "[acceptance] Platform      : $PLATFORM"
echo "[acceptance] Base image    : $BASE_IMAGE"
echo "[acceptance] Image tag     : $IMAGE_TAG"

DOCKER_BUILDKIT=1 docker build \
  --platform "$PLATFORM" \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  -f "$ZIG_DIR/docker/Dockerfile.acceptance" \
  -t "$IMAGE_TAG" \
  "$PARENT_DIR"

echo
echo "[acceptance] Running tests inside the container..."
docker run --rm \
  --platform "$PLATFORM" \
  --name awr-v3-acceptance-run \
  "$IMAGE_TAG"
