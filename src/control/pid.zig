const std = @import("std");

pub const PidController = struct {
    kp: f32 = 0.5,
    ki: f32 = 0.0,
    kd: f32 = 0.0,
    prev_error: f32 = 0.0,
    integral: f32 = 0.0,
    prev_time_ns: i128 = 0,

    pub fn init(kp: f32, ki: f32, kd: f32) PidController {
        return .{
            .kp = kp,
            .ki = ki,
            .kd = kd,
            .prev_time_ns = std.time.nanoTimestamp(),
        };
    }

    pub fn compute(self: *PidController, error_val: f32) f32 {
        const now = std.time.nanoTimestamp();
        const dt_ns = now - self.prev_time_ns;
        const dt: f32 = @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000.0;

        if (dt <= 0) return self.kp * error_val;

        self.integral += error_val * dt;
        const derivative = if (dt > 0) (error_val - self.prev_error) / dt else 0;

        self.prev_error = error_val;
        self.prev_time_ns = now;

        return self.kp * error_val + self.ki * self.integral + self.kd * derivative;
    }

    pub fn reset(self: *PidController) void {
        self.prev_error = 0;
        self.integral = 0;
        self.prev_time_ns = std.time.nanoTimestamp();
    }
};

test "PID proportional only" {
    var pid = PidController.init(2.0, 0.0, 0.0);
    const output = pid.compute(10.0);
    try std.testing.expect(output == 20.0);
}

test "PID zero error" {
    var pid = PidController.init(1.0, 0.0, 0.0);
    const output = pid.compute(0.0);
    try std.testing.expect(output == 0.0);
}
