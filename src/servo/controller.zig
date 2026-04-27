const std = @import("std");
const hal = @import("../hal.zig");

pub const NUM_SERVOS: u8 = 8;

// PCA9685 constants
const LED0_ON_L: u8 = 0x06;
const PCA_FREQ: f32 = 50.0; // 50Hz for servos
const PCA_RESOLUTION: f32 = 4096.0;
const MIN_PULSE_US: f32 = 500.0;
const MAX_PULSE_US: f32 = 2400.0;
const ACTUATION_RANGE: f32 = 180.0;

/// Convert an angle (0-180) to a PCA9685 PWM off-count value
fn angleToPwm(angle: u8) u16 {
    const pulse_us = MIN_PULSE_US + (@as(f32, @floatFromInt(angle)) / ACTUATION_RANGE) * (MAX_PULSE_US - MIN_PULSE_US);
    const period_us = 1_000_000.0 / PCA_FREQ;
    const count = pulse_us / period_us * PCA_RESOLUTION;
    return @intFromFloat(std.math.clamp(count, 0.0, 4095.0));
}

pub const ServoController = struct {
    hal_ctx: *hal.HalContext,
    init_pos: [NUM_SERVOS]u8 = .{ 90, 90, 90, 90, 90, 90, 90, 90 },
    current_pos: [NUM_SERVOS]u8 = .{ 90, 90, 90, 90, 90, 90, 90, 90 },
    max_pos: [NUM_SERVOS]u8 = .{ 110, 180, 180, 180, 180, 180, 180, 180 },
    min_pos: [NUM_SERVOS]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    direction: [NUM_SERVOS]i8 = .{ -1, 1, 1, 1, 1, 1, 1, 1 },
    wiggle_id: u8 = 0,
    wiggle_dir: i8 = 1,
    wiggle_speed: u8 = 0,

    pub fn init(ctx: *hal.HalContext) ServoController {
        return .{ .hal_ctx = ctx };
    }

    /// Write a servo angle to the PCA9685 via I2C
    fn writePwm(self: *ServoController, channel: u8, angle: u8) void {
        const pwm = angleToPwm(angle);
        const reg = LED0_ON_L + @as(u8, 4) * channel;
        const on_val: u16 = 0;
        const data = [4]u8{
            @truncate(on_val),
            @truncate(on_val >> 8),
            @truncate(pwm),
            @truncate(pwm >> 8),
        };
        self.hal_ctx.i2c_pca9685.writeReg(reg, &data) catch {};
    }

    pub fn setAngle(self: *ServoController, id: u8, angle: u8) void {
        if (id >= NUM_SERVOS) return;
        const clamped = std.math.clamp(angle, self.min_pos[id], self.max_pos[id]);
        self.current_pos[id] = clamped;
        self.writePwm(id, clamped);
    }

    pub fn moveAngle(self: *ServoController, id: u8, angle_offset: i16) void {
        if (id >= NUM_SERVOS) return;
        const dir: i16 = self.direction[id];
        const base: i16 = self.init_pos[id];
        const new_pos_raw = base + (angle_offset * dir);
        const new_pos = std.math.clamp(new_pos_raw, @as(i16, self.min_pos[id]), @as(i16, self.max_pos[id]));
        const angle: u8 = @intCast(new_pos);
        self.current_pos[id] = angle;
        self.writePwm(id, angle);
    }

    pub fn setPWM(self: *ServoController, id: u8, value: u8) void {
        if (id >= NUM_SERVOS) return;
        const clamped = std.math.clamp(value, self.min_pos[id], self.max_pos[id]);
        self.current_pos[id] = clamped;
        self.init_pos[id] = clamped;
        self.writePwm(id, clamped);
    }

    pub fn moveInit(self: *ServoController) void {
        for (0..NUM_SERVOS) |i| {
            self.current_pos[i] = self.init_pos[i];
            self.writePwm(@intCast(i), self.init_pos[i]);
        }
    }

    pub fn singleServo(self: *ServoController, id: u8, dir: i8, speed: u8) void {
        if (id >= NUM_SERVOS) return;
        self.wiggle_id = id;
        self.wiggle_dir = dir;
        self.wiggle_speed = speed;
        // Apply one step of wiggle movement
        const step: i16 = @as(i16, speed) * @as(i16, dir) * self.direction[id];
        const current: i16 = self.current_pos[id];
        const new_pos = std.math.clamp(current + step, @as(i16, self.min_pos[id]), @as(i16, self.max_pos[id]));
        const angle: u8 = @intCast(new_pos);
        self.current_pos[id] = angle;
        self.writePwm(id, angle);
    }

    pub fn stopWiggle(self: *ServoController) void {
        self.wiggle_speed = 0;
    }

    pub fn resetAll(self: *ServoController) void {
        for (0..NUM_SERVOS) |i| {
            self.init_pos[i] = 90;
            self.current_pos[i] = 90;
            self.writePwm(@intCast(i), 90);
        }
    }
};

test "angleToPwm range" {
    const pwm_0 = angleToPwm(0);
    const pwm_90 = angleToPwm(90);
    const pwm_180 = angleToPwm(180);
    // At 50Hz, 500us = ~102 counts, 2400us = ~491 counts
    try std.testing.expect(pwm_0 > 90 and pwm_0 < 120);
    try std.testing.expect(pwm_90 > 250 and pwm_90 < 350);
    try std.testing.expect(pwm_180 > 450 and pwm_180 < 510);
}

test "ServoController setAngle with clamping" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var ctrl = ServoController.init(&ctx);
    ctrl.setAngle(0, 45);
    try std.testing.expectEqual(@as(u8, 45), ctrl.current_pos[0]);
    ctrl.setAngle(0, 200); // clamp to max 110
    try std.testing.expectEqual(@as(u8, 110), ctrl.current_pos[0]);
}

test "ServoController moveInit restores positions" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var ctrl = ServoController.init(&ctx);
    ctrl.current_pos[0] = 45;
    ctrl.moveInit();
    try std.testing.expectEqual(@as(u8, 90), ctrl.current_pos[0]);
}