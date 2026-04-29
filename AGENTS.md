# AGENTS.md — AWR-V3 Zig Firmware

This document provides context for coding agents working on this project.

## Project Summary

A complete Zig rewrite of the Adeept AWR-V3 robot control firmware. The original is ~2000 lines of Python across 14 modules running on a Raspberry Pi. This Zig implementation provides the same WebSocket control protocol in a single ~3MB static binary with ~1.2MB RSS, true multi-core threading, and compile-time feature selection.

## Architecture

### Core Design: RobotState Struct

All robot state lives in a single `RobotState` struct defined in `src/main.zig`. Each subsystem is a field on this struct, conditionally compiled via `@import("config")`:

```zig
pub const RobotState = struct {
    speed: u8 = 50,
    motor: if (cfg.motor) motor_mod.MotorDriver else void,
    servo: if (cfg.servo) servo_mod.ServoController else void,
    // ... etc
};
```

When a feature flag is `false`, the field becomes `void` (zero bytes) and all code paths referencing it are eliminated at compile time.

### HAL (Hardware Abstraction Layer) — `src/hal.zig`

The HAL provides interfaces for I2C, GPIO, and SPI. Simulation uses in-memory backends. On Linux, GPIO for the Pi commonly uses **memory-mapped `/dev/gpiomem`** register access (rather than legacy `/sys/class/gpio` on newer Pi OS images).

The `HalContext` struct owns all 12 hardware interfaces (2 I2C devices, 1 SPI, 9 GPIO pins) and is passed by pointer to all subsystems.

The I2C device also exposes `rawWrite`/`rawRead` methods for devices like the ADS7830 that use command-byte protocols instead of register-based addressing.

### WebSocket Server — `src/net/ws_server.zig`

- **Raw TCP** — does not use `std.http.Server` (which cannot expose arbitrary HTTP headers for WebSocket upgrade). Instead, reads the HTTP upgrade request byte-by-byte, parses headers manually, computes SHA-1 accept key, and sends the 101 response.
- **RFC 6455 framing** — `readWsFrame()` handles masking, extended payload lengths (126/127), and `sendWsText()` builds unmasked server frames.
- **Thread-per-connection** — each accepted connection spawns a detached thread via `std.Thread.spawn()`.
- **Mutex synchronization** — all `RobotState` mutations are protected by `robot_mutex`. Each command branch uses an **inner block scope** with `defer robot_mutex.unlock()` so the mutex is released at block exit before `continue`/`break`. This is critical — Zig's `defer` scopes to the enclosing block, NOT the function, so placing lock/defer-unlock at function scope inside a loop would deadlock.
- **Credentials** — loaded from `AWR_WS_USER`/`AWR_WS_PASS` environment variables at startup via `std.posix.getenv()`. If not set, all authentication attempts are rejected.

### Protocol — `src/net/protocol.zig`

Command classification functions (`isMovementCmd`, `isStopCmd`, `isTiltCmd`, etc.) and a `formatResponse()` function that builds JSON manually. Note: JSON values are not escaped — this is acceptable because all protocol values are controlled (status/title are compile-time strings, data values are formatted numbers).

### SLAM — `src/slam/`

- **occupancy_grid.zig**: 80x80 grid using Bayesian log-odds. `updateCell()` adds LOG_ODDS_FREE (-0.4) or LOG_ODDS_OCC (+0.85), clamped to [-5, 5]. Cell state thresholds: <-0.5 = free, >0.5 = occupied, else unknown. `scanUltrasonic(distance_cells, heading, endpoint_is_obstacle)` performs ray-casting along the **current pose heading**. The grid also owns the dead-reckoned pose (`pose_x`, `pose_y` as floats; `pose_theta_rad`). `applyTranslate(step_cm, direction)` and `applyRotate(delta_rad)` integrate movement commands. `encodeAscii()` serialises to `?`/`.`/`#` for streaming. `CELL_CM` = 10 (one cell per 10 cm).
- **path_planner.zig**: A* with Manhattan heuristic, fixed-size open list (2048 nodes), fixed-size closed/parent arrays (80x80). Returns path as a slice into a caller-provided buffer. `Point` is `pub` so the WebSocket dispatcher can call `findPath` directly.

### Live SLAM dispatch — `src/net/ws_server.zig`

The WebSocket server runs a **single background mapping thread** (global `slam_thread` + `slam_stop`) that ticks every 250 ms while `robot.mapping` is true. Each tick reads the ultrasonic sensor and casts a ray on the occupancy grid using the current heading. Pose updates are applied **synchronously** when the standard `forward`/`backward`/`rotate-*` commands arrive, so the map reflects driver actions even when mapping is later toggled on. Protocol surface:

- `mapping` → `startMappingThread`
- `mappingOff` → `stopMappingThread` (joins the thread)
- `slam_reset` → `OccupancyGrid.reset()` under `robot_mutex`
- `get_map` → `formatGetMapResponse` writes `{title:"get_map", data:{size, cell_cm, x, y, theta, frontiers, coverage, mapping, grid}}`. Grid is encoded inline using `encodeAscii` to avoid an extra copy. The whole response is staged in an arena allocator so payloads can exceed the 4 KiB stack frame.
- `slam_plan X Y` → calls `path_planner.findPath` from the current pose to the requested cell with a 2048-point buffer, returns `{found, length}`.

Because `get_map` payloads can be 6.4 KiB+ (80×80 grid + envelope), `sendWsText` was rewritten to write a 2/4/10-byte WS header followed by the payload using two `writeAll` calls, removing the previous 4 KiB limit.

## Key Files

| File | Purpose | Lines |
|------|---------|-------|
| `build.zig` | Build system with 11 feature toggles | ~80 |
| `src/main.zig` | Entry point, RobotState definition (incl. `mapping` flag) | ~110 |
| `src/hal.zig` | HAL with Sim + Linux backends (`/dev/gpiomem`) | ~387 |
| `src/net/ws_server.zig` | WebSocket server + SLAM dispatch + mapping thread | ~580 |
| `src/net/protocol.zig` | Command classification (incl. `isSlamCmd`), JSON formatting | ~135 |
| `src/motor/driver.zig` | 4-motor PCA9685 driver | ~132 |
| `src/servo/controller.zig` | 8-channel servo controller | ~138 |
| `src/led/ws2812.zig` | WS2812 SPI driver + 4 effects | ~222 |
| `src/slam/occupancy_grid.zig` | Bayesian occupancy grid + pose tracking + ASCII encoder | ~190 |
| `src/slam/path_planner.zig` | A* pathfinding (with `pub Point`) | ~190 |
| `src/audio/buzzer.zig` | 14-note buzzer with GPIO PWM | ~142 |
| `scripts/install-pi.sh` | One-shot Pi installer (Zig + service + helper) | ~150 |
| `scripts/awr-stack` | Toggle helper between vendor Python and Zig services | ~80 |
| `scripts/uninstall-pi.sh` | Removes Zig stack only | ~25 |

## Build Commands

Requires **Zig 0.14.x** (this repository’s `build.zig` matches the 0.14 `std.Build` API). On macOS: `brew install zig@0.14` and prepend `/opt/homebrew/opt/zig@0.14/bin` to `PATH`.

```bash
zig build -Dsim=true                    # Build for simulation (any host)
zig build test -Dsim=true               # Run unit tests
zig build -Dsim=false -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseFast  # Cross-compile for Pi
```

## Conventions & Gotchas

- **Mutex scoping**: Always use inner `{ robot_mutex.lock(); defer robot_mutex.unlock(); ... }` blocks, never lock at loop/function scope
- **Comptime conditionals**: Use `if (cfg.feature)` to guard subsystem access. The compiler eliminates dead branches entirely.
- **HAL error handling**: Motor/servo write methods use `catch {}` to silently ignore I2C errors (hardware may not be present in simulation). Sensor reads return fallback values on error.
- **No allocator usage in hot paths**: The WebSocket server, protocol parser, and all subsystem drivers use only stack-allocated buffers
- **`stop_requested` in buzzer**: Must be cleared at the start of `playNote()` and `playTune()` so a previous `stop()` call does not permanently latch cancellation
- **PCA9685 register layout**: Each PWM channel has 4 registers at `0x06 + 4*channel` (ON_L, ON_H, OFF_L, OFF_H). 12-bit resolution (0-4095).
- **ADS7830 uses raw I2C**: Not register-based. Use `rawWrite(&[_]u8{cmd_byte})` then `rawRead()`, not `writeReg`/`readReg`.

## Companion Projects

- **`adeept-dashboard`**: React cockpit that connects over WebSocket only. It ships:
  - A **Node** `ws-server.mjs` simulator and `npm run test:protocol` for the AWR-V3 command
    contract (including the SLAM track).
  - Two **Playwright** projects: `chromium` (default; runs the UI against the Node simulator —
    87 tests, ~58 s) and `chromium-live-pi` (drives the same UI against a real Pi running this
    Zig firmware — 48 tests, ~3 min, asserts hardware via SSH+`smbus2` PCA9685 reads and
    SSH+`pinctrl` GPIO reads). The orchestrator for the live-Pi run lives in this repo at
    `scripts/run-live-pi-e2e.sh`.
  Run Zig or Python robot firmware on the Pi; run the dashboard on a development machine on
  the same LAN.
- **Original Python firmware** (`Adeept_AWR-V3/Server/…`): reference implementation; often `ws://<pi>:8888`, Flask camera on `http://<pi>:5000`. Coexists with this stack via `awr-stack`.

## Pi installation & coexistence

`scripts/install-pi.sh` is the equivalent of the vendor `setup.py`. It is **additive** — it never disables or rewrites `Adeept_Robot.service`. It installs Zig 0.14.x, copies the repo to `/opt/awr-v3-zig`, builds the binary, drops `/etc/awr-v3-zig/credentials.env` (chmod 600), and registers `awr-v3-zig.service` (DISABLED on first install).

`scripts/awr-stack` is a tiny systemd wrapper:

- `awr-stack zig` → stop+disable vendor, enable+start Zig
- `awr-stack python` → stop+disable Zig, enable+start vendor
- `awr-stack both` → enable both (warns about GPIO/I2C contention)
- `awr-stack stop` → stop both
- `awr-stack status` → enable + active state for both
- `awr-stack logs-zig` / `logs-python` → `journalctl -fu …`

Both stacks share the I2C/GPIO peripherals on real hardware, so only one should run at a time on the HAT. Use the dashboard's connection presets (`Python robot` vs `Zig robot`) to point at whichever is active.

## Functional acceptance test (Docker / Raspberry Pi OS)

Use this when you cannot reach a real Pi but want empirical evidence that **install → run → control plane → protocol → coexistence → uninstall** all work end-to-end for **both** the vendor Python and the Zig firmware.

```bash
# Optional: point at vendor V3 source (auto-detected from
# ~/Downloads/Adeept_AWR-V3-*/Code/Adeept_AWR-V3 if not set)
export VENDOR_SRC=/path/to/Adeept_AWR-V3
bash zig-awr-v3/scripts/run-functional-acceptance.sh
```

Expectations the agent should encode in any change:

- The orchestrator (`scripts/acceptance/run-in-container.sh`) exits **non-zero** if any assertion fails. The final line must be **`PASS: <n>` / `FAIL: 0`** — currently 115 / 0 (88 control / protocol / coexistence + 25 in-situ rehearsal + 2 meta-asserts).
- The suite is **dual-stack first**. Phases A–H exercise the Zig firmware in isolation. Phases I–M install and exercise the vendor Adeept Python firmware (`setup.py` + `WebServer.py`) on top of the Zig install, prove both run concurrently (vendor on `:8888`, Zig on `:8889`), prove `awr-stack` toggles cleanly with both present, and prove a full uninstall returns the system to a clean state. **Phase N** runs `scripts/in-situ-test.sh --rehearsal` end-to-end against the same Bookworm container (forwarded into the outer summary so any in-situ regression reduces the outer PASS count). Treat any deviation in cross-stack coexistence — Zig clobbering vendor or vice versa — as a hard failure.
- Each phase is **independent**: a phase failing must not silently invalidate later phases. `set -uo pipefail` (no `-e`) keeps the harness running so we get the full report.
- The systemctl stub (`docker/stub-systemctl`) is the **only** authority that proves what `install-pi.sh`, the vendor `setup.py`, and `awr-stack` actually called. Add new control-plane assertions by `grep`-ing `/var/log/stub-systemctl.log`.
- The black-box `scripts/acceptance/ws-protocol-test.mjs` runs against **three** backends and asserts a different envelope per backend label:
  - `BACKEND_LABEL=zig INCLUDE_SLAM=1` — Zig binary at `:8889` (full SLAM).
  - `BACKEND_LABEL=vendor` — vendor Python `WebServer.py` at `:8888` (common subset, no SLAM, `get_info` length ≥ 3).
  - dashboard `tests/ws-protocol.test.mjs` — Node simulator at `:8889` (with `/state` HTTP helpers).

  Any new WebSocket command must land in **all three** if it's universal, or in the SLAM-gated branch only if it's a Zig-specific extension.
- Build the Zig binary with `--build-mode sim`. The HAL must remain side-effect free in sim mode (no `/dev/gpiomem`, `/dev/i2c-1`, `/dev/spidev0.0` access) or the binary won't start under the Pi OS userspace running in Docker.
- Vendor Python is run with hardware stubs in `docker/vendor_stubs/`. **Do not** add Python-side hardware imports to those stubs unless a vendor `WebServer.py` change requires it; the stubs exist purely to make the vendor's protocol code reachable in Docker, not to simulate hardware.
- The acceptance run is ~100 s on Apple Silicon (Docker layer-caches `apt`, Node, Python, and the repo COPY; Zig 0.14.1 is fetched fresh inside the container — note `zig-aarch64-linux-0.14.1.tar.xz`, the arch-os ordering changed at 0.14).

If a real Pi becomes available, the same install scripts run unchanged: just drop `--build-mode sim` (defaults to `real`), use the real vendor `setup.py` (no patching needed because the apt/pip/reboot lines are intentional on hardware), and `awr-stack zig` / `awr-stack python` to toggle live.

## In-situ acceptance test (real hardware on the Pi)

`scripts/in-situ-test.sh` is the on-Pi counterpart to the Docker suite. It is **the contract for "does it actually work on hardware"**: install + boot + protocol + dual-stack + awr-stack + restore, all against `/dev/gpiomem`, real I2C ADS7830/PCA9685, real systemd, real LAN. Drive it from the developer host:

```bash
bash zig-awr-v3/scripts/run-in-situ-test.sh \
  --host raspberry-pi.local --user dmz \
  --remote-protocol           # also re-run the WS test from the host
```

Expectations the agent should encode in any change:

- The Pi-side runner (`scripts/in-situ-test.sh`) is **safe by default** — `--no-motion` is auto-enabled when battery is < 50% (overridable with `--allow-low-battery`). When in `--no-motion`, motor / servo-driving commands are dropped from the protocol test via `WS_SKIP_MOTION=1` and SLAM is force-disabled. Add `--with-slam` only when the wheels are clear.
- **Rehearsal mode** (`--rehearsal`, auto-enabled when `/.dockerenv` exists or `/dev/gpiomem` is missing) skips the hardware probes (Pi sysfs, `/dev/gpiomem`, `/dev/i2c-1`, `/dev/spidev0.0`, `i2cdetect`), skips the ADS7830 battery readout, forces `--build-mode sim`, asserts `awr-stack` against `$SYSTEMCTL_STUB_LOG` (the Docker-image's recording stub), and routes vendor `WebServer.py` through `scripts/acceptance/run-vendor-server.sh` (with the `docker/vendor_stubs/` PYTHONPATH) so the same code path runs in CI. **Anything you change in `in-situ-test.sh` must keep Phase N of the Docker acceptance green** — it's the cheap regression net for this script before the Pi sees it.
- The runner **snapshots** the systemd state of `Adeept_Robot.service` and `awr-v3-zig.service` before doing anything, and **restores** that snapshot in phase J unless the operator passes `--keep-zig` / `--keep-vendor` / `--keep-current`. Never leave the Pi in a different stack state than the operator started in.
- Phase A asserts hardware presence (`/dev/gpiomem`, `/dev/i2c-1`, `/dev/spidev0.0`, `i2cdetect -y 1` finds 0x40 + 0x48). If you change the HAT wiring, those assertions move with you.
- Phase E starts the Zig binary in the foreground and runs `ws-protocol-test.mjs` over `ws://127.0.0.1:8889`. Phase H does the same with vendor `WebServer.py` on `:8888` and Zig on `:8889` **concurrently**. Phase F drives `awr-stack` against **real systemd** (no stub) and asserts the right port becomes / stops being bound.
- Treat any drift between the Docker phases (A–M) and the in-situ phases (A–J) as a fixable inconsistency — both must keep passing. The Docker version covers control-plane / protocol; the in-situ version covers everything the Docker version cannot (real GPIO/I2C/SPI, real systemd, real LAN).
- The host-side driver (`scripts/run-in-situ-test.sh`) is just `rsync + ssh`; it intentionally does not have its own logic so the Pi-side script remains the single source of truth.

If you change anything in `install-pi.sh`, `awr-stack`, the WebSocket protocol, or the SLAM dispatch, you must verify both the Docker suite (`PASS: <N> / FAIL: 0`) and the in-situ suite are still green.

## Live-Pi Playwright suite (UI ↔ Zig firmware ↔ hardware)

The on-Pi runner above covers protocol-level conformance. The complementary
**`scripts/run-live-pi-e2e.sh`** orchestrator drives the dashboard's
`chromium-live-pi` Playwright project against the same Pi to verify
the full *user-visible* chain — React UI → WebSocket frame → Zig dispatcher →
PCA9685 / GPIO → motor coils + LEDs + servo. The suite reads PCA9685 channel
duty cycles via `smbus2` (over SSH) and GPIO pin levels via `pinctrl` to assert
the firmware actually drove the right hardware for each user action.

```bash
bash scripts/run-live-pi-e2e.sh \
    --host raspberry-pi.local --user dmz --password 'YOUR_PI_PASSWORD'
# (or --use-agent for SSH key + agent auth)
```

Expectations the agent should encode in any change:

- The orchestrator switches the Pi to `awr-stack zig` before the suite runs and
  pre-flight-asserts that PCA9685 ch08–ch15 = 0; it refuses to start if motors are
  not idle. After the suite it post-flights the same way.
- A `trap '...' EXIT INT TERM` always quiesces the firmware on the way out, so a
  failed test or Ctrl-C does not leave the wheels spinning.
- Live-Pi specs live in `adeept-dashboard/tests/e2e/live/`. Page objects are shared
  with the simulator suite under `adeept-dashboard/tests/e2e/pages/`. Hardware
  probes are isolated in `tests/e2e/utils/pi-pca9685.ts` (with the `MOTOR_INTENT`
  table derived from `src/motor/driver.zig`'s `MOTOR_CHANNELS` + `MOTOR_DIRS`) and
  `tests/e2e/utils/pi-gpio.ts`.
- Anything that changes the Zig dispatch table (new commands, channel remap, GPIO
  remap, etc.) must keep this suite green. If you change `MOTOR_CHANNELS` or
  `MOTOR_DIRS` in `motor/driver.zig`, you must also update `MOTOR_INTENT` in
  `pi-pca9685.ts` — they are the same contract expressed twice.
- The Zig firmware acks every command with `{status:ok}`, so the dashboard's
  command log doubles as a generic "did the firmware accept this frame?" probe
  for vendor-only commands (lights effects, CV modes) that the Zig firmware
  silently ignores today. The live-Pi suite asserts those via the log instead of
  via hardware.

## Original Python Codebase Reference

This firmware reimplements the protocol from these original Python files:

| Original Python | Zig Equivalent | Notes |
|----------------|----------------|-------|
| `WebServer.py` | `net/ws_server.zig` | WebSocket command dispatch |
| `Move.py` | `motor/driver.zig` | Motor channel mapping identical |
| `RPIservo.py` | `servo/controller.zig` | Same direction/limit arrays |
| `Ultra.py` | `sensor/ultrasonic.zig` | GPIO 23/24 trigger/echo |
| `Voltage.py` | `sensor/battery.zig` | ADS7830 at 0x48 |
| `Functions.py` | `main.zig` (FunctionState) | State flags, no autonomous loops yet |
| `RobotLight.py` | `led/ws2812.zig` | SPI encoding matches numpy8 method |
| `Buzzer.py` | `audio/buzzer.zig` | Same Happy Birthday melody |
| `Switch.py` | `hal.zig` (GPIO LED pins) | Direct GPIO write |
| `PID.py` | `control/pid.zig` | Same algorithm |
| `Kalman_Filter.py` | `control/kalman.zig` | Same algorithm |
| `app.py` | `net/ws_server.zig` (HTTP fallback) | Serves plain text, no Flask |
| `camera_opencv.py` | Not implemented | Camera/vision requires V4L2 integration |

## Future Work

- **Camera/vision**: Implement V4L2 capture and MJPEG streaming. The original uses picamera2 + OpenCV; the Zig equivalent would use V4L2 ioctl + manual JPEG encoding or link against libjpeg.
- **Autonomous behaviors**: `Functions.py` obstacle avoidance, line tracking, and keep-distance loops are represented as state flags but the actual control loops are not yet implemented in Zig.
- **Wheel encoders / IMU**: Pose is currently dead-reckoned from movement commands. Adding an MPU6050 or wheel encoders would significantly improve the live SLAM map fidelity.
- **Path execution**: `slam_plan` returns a length but the firmware does not yet drive along the returned path. A safe execution mode (with sonar-aware abort) is the next step.