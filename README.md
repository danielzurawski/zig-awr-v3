# AWR-V3 Zig Firmware

A high-performance Zig rewrite of the [Adeept AWR-V3](https://www.adeept.com/) robot control firmware, designed to run on Raspberry Pi 3B/3B+/4/5 with the Adeept Robot HAT V3.2.

## Why Zig?

The original AWR-V3 firmware is Python with 15+ pip dependencies, consuming ~200MB RAM with 3-8 second startup. This Zig implementation compiles to a **single ~3MB static binary** using **~1.2MB RAM** at runtime, with sub-50ms startup and true multi-core parallelism (no GIL).

| Metric | Python (Original) | Zig (This Project) |
|--------|-------------------|-------------------|
| Binary size | ~200MB (interpreter + libs) | ~3MB (static) |
| Runtime RSS | ~150-250MB | ~1.2MB |
| Dependencies | 15+ pip + apt packages | Zero |
| Startup | 3-8 seconds | <50ms |
| Thread model | GIL-limited | True 4-core parallelism |

## Features

- **11 compile-time feature toggles** — enable/disable subsystems at build time
- **Dual HAL backends** — simulation (in-memory) and real Linux (**I2C** via `ioctl`, **SPI** via `/dev/spidev*`, GPIO via memory-mapped **`/dev/gpiomem`** on Raspberry Pi targets)
- **4-motor differential drive** — PCA9685 PWM register-level control
- **8-channel servo controller** — pulse-width calculation with clamping and wiggle mode
- **HC-SR04 ultrasonic** — GPIO trigger/echo with explicit timeout handling
- **ADS7830 battery monitor** — raw I2C ADC with voltage divider calculation
- **3-channel IR line tracker** — binary sensor status encoding
- **WS2812 LED driver** — SPI bit-encoded protocol with breath, police, rainbow, and flowing effects
- **Buzzer** — 14-note frequency table with GPIO PWM tone generation
- **PID controller** and **Kalman filter**
- **SLAM occupancy grid** — 80x80 Bayesian log-odds grid with frontier detection
- **A\* path planner** — operates on the occupancy grid
- **WebSocket server** — raw TCP with RFC 6455 framing, mutex-synchronized state, environment-based credentials

## Prerequisites

- [Zig](https://ziglang.org/download/) **0.14.x**. This repo’s `build.zig` targets the Zig 0.14 build API (Zig **0.15+** renamed several `std.Build` options — use **0.14.x** until the project is ported).
- On macOS with Homebrew: `brew install zig@0.14` then put `/opt/homebrew/opt/zig@0.14/bin` first on your `PATH`.
- No other dependencies

## Quick Start

### Build and Run (Simulation Mode)

```bash
# Build with simulation HAL (for development/testing on any platform)
zig build -Dsim=true

# Run the server
AWR_WS_USER=admin AWR_WS_PASS=123456 ./zig-out/bin/awr-v3
```

The server starts on `ws://0.0.0.0:8889` with all subsystems enabled.

### Cross-Compile for Raspberry Pi

```bash
# Build for Pi 3B/3B+/4 (aarch64)
zig build -Dsim=false -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseFast

# Copy to Pi
scp zig-out/bin/awr-v3 pi@<PI_IP>:~/awr-v3

# Run on Pi
ssh pi@<PI_IP>
AWR_WS_USER=admin AWR_WS_PASS=123456 sudo ./awr-v3
```

### Feature Toggles

Every subsystem can be independently enabled/disabled at compile time:

```bash
# Full build (default)
zig build -Dsim=true

# Minimal: motor + servo only
zig build -Dsim=true -Dslam=false -Dcamera=false -Dbuzzer=false -Dled=false -Dbattery=false -Dultrasonic=false -Dline_tracker=false -Dautonomy=false

# SLAM-focused build
zig build -Dsim=true -Dbuzzer=false -Dled=false
```

Available flags: `-Dmotor`, `-Dservo`, `-Dultrasonic`, `-Dline_tracker`, `-Dbattery`, `-Dled`, `-Dbuzzer`, `-Dcamera`, `-Dslam`, `-Dautonomy`, `-Dsim`

Disabled subsystems compile to `void` (zero bytes) and all related code is eliminated.

## Running Tests

```bash
# Run all 38 unit tests
zig build test -Dsim=true
```

Companion **`adeept-dashboard`** provides **Node** WebSocket protocol acceptance tests (`npm run test:protocol`) against `ws-server.mjs`. That harness uses simulator-only HTTP helpers such as **`/capabilities`** and **`/state`** alongside the WebSocket stream. The Zig firmware validates with **`zig build test`**, on-device trials, and connecting the React dashboard to **`ws://<lan-ip>:8889`**.

## Project Structure

```
zig-awr-v3/
├── build.zig                          # Build system with feature toggles
├── src/
│   ├── main.zig                       # Entry point, RobotState struct
│   ├── hal.zig                        # Hardware abstraction (Sim + Linux backends)
│   ├── motor/driver.zig               # 4-motor differential drive via PCA9685
│   ├── servo/controller.zig           # 8-ch servo with pulse-width calc
│   ├── sensor/
│   │   ├── ultrasonic.zig             # HC-SR04 with timeout handling
│   │   ├── battery.zig                # ADS7830 ADC battery monitor
│   │   └── line_tracker.zig           # 3-channel IR binary reader
│   ├── led/ws2812.zig                 # WS2812 SPI driver + 4 effect modes
│   ├── audio/buzzer.zig               # 14-note frequency table + GPIO PWM
│   ├── control/
│   │   ├── pid.zig                    # PID controller
│   │   └── kalman.zig                 # Kalman filter
│   ├── slam/
│   │   ├── occupancy_grid.zig         # 80x80 Bayesian log-odds grid
│   │   └── path_planner.zig           # A* pathfinding
│   └── net/
│       ├── ws_server.zig              # WebSocket server (raw TCP + RFC 6455)
│       └── protocol.zig               # Command parser + JSON response builder
```

## WebSocket Protocol

Compatible with the original Adeept AWR-V3 Python server protocol. Authentication uses environment variables:

```bash
export AWR_WS_USER=admin
export AWR_WS_PASS=123456
```

All commands from the original protocol are supported: movement, camera tilt, speed, function toggles, switch control, servo calibration, JSON payloads, and `get_info` telemetry.

## Hardware

Designed for the Adeept Robot HAT V3.2:

| Device | Interface | Address | Zig Module |
|--------|-----------|---------|------------|
| PCA9685 (PWM) | I2C | 0x5f | `hal.zig` → `motor/driver.zig`, `servo/controller.zig` |
| ADS7830 (ADC) | I2C | 0x48 | `hal.zig` → `sensor/battery.zig` |
| HC-SR04 | GPIO 23/24 | — | `sensor/ultrasonic.zig` |
| Line Tracker | GPIO 22/27/17 | — | `sensor/line_tracker.zig` |
| WS2812 LEDs | SPI0 (GPIO 10) | — | `led/ws2812.zig` |
| Buzzer | GPIO 18 | — | `audio/buzzer.zig` |
| LEDs 1-3 | GPIO 9/25/11 | — | `hal.zig` (direct GPIO) |

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.