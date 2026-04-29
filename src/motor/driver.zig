const std = @import("std");
const hal = @import("../hal.zig");

// PCA9685 registers
const MODE1: u8 = 0x00;
const PRESCALE: u8 = 0xFE;
const LED0_ON_L: u8 = 0x06;

// MODE1 bits
const MODE1_RESTART: u8 = 0x80;
const MODE1_EXTCLK: u8 = 0x40;
const MODE1_AI: u8 = 0x20; // auto-increment register pointer on writes
const MODE1_SLEEP: u8 = 0x10; // low-power mode (oscillator off — must clear)

// 25 MHz internal oscillator / (4096 * (prescale + 1)) = output Hz.
// For 50 Hz (servos + the Adeept motor driver): prescale = 121.
const PCA_PRESCALE_50HZ: u8 = 121;

// Motor channel assignments matching Move.py
const MOTOR_CHANNELS = [4][2]u8{
    .{ 15, 14 }, // M1: IN1=ch15, IN2=ch14
    .{ 12, 13 }, // M2: IN1=ch12, IN2=ch13
    .{ 11, 10 }, // M3: IN1=ch11, IN2=ch10
    .{ 8, 9 }, // M4: IN1=ch8,  IN2=ch9
};

const MOTOR_DIRS = [4]i8{ 1, -1, 1, -1 };

/// Wake the PCA9685 from its power-on default (SLEEP=1, AI=0), set the
/// 50 Hz prescale required for both servos and the H-bridge inputs,
/// then re-enable AUTO_INCREMENT so multi-byte channel writes actually
/// land on consecutive registers.
///
/// Without this the chip stays in either:
///   * power-on default (SLEEP=1, AI=0) — no PWM output at all, and
///     multi-byte writes overwrite a single register repeatedly; or
///   * a state left by Adafruit's `PCA9685(i2c)` constructor, which
///     resets MODE1 to 0 (clears AI). Any tooling that reads the chip
///     via Adafruit (including the in-situ test) will silently break
///     subsequent firmware writes if AI isn't re-asserted by us.
///
/// Idempotent and safe to call repeatedly.
pub fn initPca9685(ctx: *hal.HalContext) void {
    // Step 1: enter SLEEP so the prescaler is writable.
    ctx.i2c_pca9685.writeReg(MODE1, &[_]u8{MODE1_SLEEP}) catch {};
    // Step 2: set prescale for 50 Hz.
    ctx.i2c_pca9685.writeReg(PRESCALE, &[_]u8{PCA_PRESCALE_50HZ}) catch {};
    // Step 3: leave SLEEP, enable AUTO_INCREMENT.
    ctx.i2c_pca9685.writeReg(MODE1, &[_]u8{MODE1_AI}) catch {};
    // Step 4: PCA9685 datasheet requires ≥500 µs after clearing SLEEP
    // before normal operation; 5 ms is a generous margin used by every
    // CircuitPython PCA9685 driver.
    std.time.sleep(5 * std.time.ns_per_ms);
    // Step 5: send RESTART (per datasheet, after the oscillator stabilises).
    ctx.i2c_pca9685.writeReg(MODE1, &[_]u8{MODE1_RESTART | MODE1_AI}) catch {};
}

pub const MotorDriver = struct {
    hal_ctx: *hal.HalContext,
    throttle: [4]i16 = .{ 0, 0, 0, 0 },

    /// Constructs the driver, configures the PCA9685 (see `initPca9685`),
    /// and unconditionally zeroes every motor channel ("safe boot"). The
    /// PCA9685 retains PWM duty cycles across host-process restarts, so
    /// without `stop()` here a previous run that left motors mid-command
    /// would keep the wheels spinning until the next motor command —
    /// dangerous for a robot on a stand or unattended on the floor.
    pub fn init(ctx: *hal.HalContext) MotorDriver {
        initPca9685(ctx);
        var driver = MotorDriver{ .hal_ctx = ctx };
        driver.stop();
        return driver;
    }

    /// Write a PWM value to a PCA9685 channel.
    /// PCA9685 uses 12-bit (0-4095) PWM values.
    /// Each channel has 4 registers: ON_L, ON_H, OFF_L, OFF_H at base + 4*ch.
    fn setPwmChannel(self: *MotorDriver, channel: u8, pwm_value: u16) void {
        const reg = LED0_ON_L + @as(u8, 4) * channel;
        const on_val: u16 = 0;
        const off_val: u16 = @min(pwm_value, 4095);
        const data = [4]u8{
            @truncate(on_val), // ON_L
            @truncate(on_val >> 8), // ON_H
            @truncate(off_val), // OFF_L
            @truncate(off_val >> 8), // OFF_H
        };
        self.hal_ctx.i2c_pca9685.writeReg(reg, &data) catch {};
    }

    /// Drive a single motor with direction and speed (0-100%)
    fn setMotor(self: *MotorDriver, motor_idx: u2, direction: i8, speed_pct: u8) void {
        const clamped = @min(speed_pct, 100);
        const pwm_val: u16 = @intFromFloat(@as(f32, @floatFromInt(clamped)) / 100.0 * 4095.0);
        const in1 = MOTOR_CHANNELS[motor_idx][0];
        const in2 = MOTOR_CHANNELS[motor_idx][1];

        if (direction >= 0) {
            self.setPwmChannel(in1, pwm_val);
            self.setPwmChannel(in2, 0);
        } else {
            self.setPwmChannel(in1, 0);
            self.setPwmChannel(in2, pwm_val);
        }
        self.throttle[motor_idx] = if (direction >= 0) @as(i16, clamped) else -@as(i16, clamped);
    }

    /// Differential drive: direction=1 forward, -1 backward. turn: "mid","left","right","rotate-left","rotate-right"
    pub fn move(self: *MotorDriver, speed_pct: u8, direction: i8, turn: []const u8) void {
        if (speed_pct == 0) {
            self.stop();
            return;
        }
        const radius: f32 = 0.3;
        const reduced: u8 = @intFromFloat(@as(f32, @floatFromInt(speed_pct)) * radius);

        if (direction == 1) {
            if (std.mem.eql(u8, turn, "rotate-left")) {
                self.setMotor(0, MOTOR_DIRS[0], speed_pct);
                self.setMotor(1, MOTOR_DIRS[1], speed_pct);
                self.setMotor(2, -MOTOR_DIRS[2], speed_pct);
                self.setMotor(3, -MOTOR_DIRS[3], speed_pct);
            } else if (std.mem.eql(u8, turn, "rotate-right")) {
                self.setMotor(0, -MOTOR_DIRS[0], speed_pct);
                self.setMotor(1, -MOTOR_DIRS[1], speed_pct);
                self.setMotor(2, MOTOR_DIRS[2], speed_pct);
                self.setMotor(3, MOTOR_DIRS[3], speed_pct);
            } else if (std.mem.eql(u8, turn, "left")) {
                self.setMotor(0, MOTOR_DIRS[0], speed_pct);
                self.setMotor(1, MOTOR_DIRS[1], speed_pct);
                self.setMotor(2, MOTOR_DIRS[2], reduced);
                self.setMotor(3, MOTOR_DIRS[3], reduced);
            } else if (std.mem.eql(u8, turn, "right")) {
                self.setMotor(0, MOTOR_DIRS[0], reduced);
                self.setMotor(1, MOTOR_DIRS[1], reduced);
                self.setMotor(2, MOTOR_DIRS[2], speed_pct);
                self.setMotor(3, MOTOR_DIRS[3], speed_pct);
            } else {
                self.setMotor(0, MOTOR_DIRS[0], speed_pct);
                self.setMotor(1, MOTOR_DIRS[1], speed_pct);
                self.setMotor(2, MOTOR_DIRS[2], speed_pct);
                self.setMotor(3, MOTOR_DIRS[3], speed_pct);
            }
        } else {
            self.setMotor(0, -MOTOR_DIRS[0], speed_pct);
            self.setMotor(1, -MOTOR_DIRS[1], speed_pct);
            self.setMotor(2, -MOTOR_DIRS[2], speed_pct);
            self.setMotor(3, -MOTOR_DIRS[3], speed_pct);
        }
    }

    pub fn stop(self: *MotorDriver) void {
        for (0..4) |i| {
            const idx: u2 = @intCast(i);
            self.setPwmChannel(MOTOR_CHANNELS[idx][0], 0);
            self.setPwmChannel(MOTOR_CHANNELS[idx][1], 0);
            self.throttle[i] = 0;
        }
    }
};

test "MotorDriver init and stop" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var driver = MotorDriver.init(&ctx);
    driver.move(50, 1, "mid");
    try std.testing.expect(driver.throttle[0] != 0);
    driver.stop();
    try std.testing.expectEqual(@as(i16, 0), driver.throttle[0]);
    try std.testing.expectEqual(@as(i16, 0), driver.throttle[3]);
}

test "MotorDriver rotation" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var driver = MotorDriver.init(&ctx);
    driver.move(80, 1, "rotate-left");
    // M1,M2 forward; M3,M4 reversed
    try std.testing.expect(driver.throttle[0] > 0);
    try std.testing.expect(driver.throttle[2] < 0);
    driver.stop();
}
