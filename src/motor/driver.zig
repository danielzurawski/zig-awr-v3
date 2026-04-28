const std = @import("std");
const hal = @import("../hal.zig");

// PCA9685 register base for LED/PWM channels
const LED0_ON_L: u8 = 0x06;

// Motor channel assignments matching Move.py
const MOTOR_CHANNELS = [4][2]u8{
    .{ 15, 14 }, // M1: IN1=ch15, IN2=ch14
    .{ 12, 13 }, // M2: IN1=ch12, IN2=ch13
    .{ 11, 10 }, // M3: IN1=ch11, IN2=ch10
    .{ 8, 9 }, // M4: IN1=ch8,  IN2=ch9
};

const MOTOR_DIRS = [4]i8{ 1, -1, 1, -1 };

pub const MotorDriver = struct {
    hal_ctx: *hal.HalContext,
    throttle: [4]i16 = .{ 0, 0, 0, 0 },

    pub fn init(ctx: *hal.HalContext) MotorDriver {
        return .{ .hal_ctx = ctx };
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
