const std = @import("std");
const hal = @import("../hal.zig");
const cfg = @import("config");

const MAX_DISTANCE_CM: f32 = 200.0;
const TIMEOUT_ITERATIONS: u32 = 100_000;

pub const MeasurementError = error{
    EchoTimeout,
};

pub const Ultrasonic = struct {
    hal_ctx: *hal.HalContext,
    last_distance_cm: f32 = 100.0,
    sim_rng: if (cfg.sim) std.Random.Xoshiro256 else void,

    pub fn init(ctx: *hal.HalContext) Ultrasonic {
        return .{
            .hal_ctx = ctx,
            .sim_rng = if (cfg.sim) std.Random.Xoshiro256.init(42) else {},
        };
    }

    pub fn readDistance(self: *Ultrasonic) f32 {
        if (cfg.sim) {
            const r = self.sim_rng.random().float(f32);
            self.last_distance_cm = 5.0 + r * 195.0;
            return self.last_distance_cm;
        } else {
            return self.measureReal() catch self.last_distance_cm;
        }
    }

    /// Real HC-SR04 measurement using GPIO trigger/echo.
    /// Protocol: send 10us HIGH pulse on trigger, then measure duration of
    /// the HIGH pulse on echo. Distance = pulse_us * 0.01715 cm.
    /// Returns error on timeout rather than producing bogus readings.
    fn measureReal(self: *Ultrasonic) !f32 {
        // Ensure trigger is LOW, then send 10us HIGH pulse
        self.hal_ctx.gpio_trig.write(false);
        std.time.sleep(2_000); // 2us settle
        self.hal_ctx.gpio_trig.write(true);
        std.time.sleep(10_000); // 10us trigger pulse
        self.hal_ctx.gpio_trig.write(false);

        // Wait for echo to go HIGH (start of return pulse)
        var timeout: u32 = 0;
        while (!self.hal_ctx.gpio_echo.read()) {
            timeout += 1;
            if (timeout >= TIMEOUT_ITERATIONS) {
                // Echo never went high: sensor not responding
                return MeasurementError.EchoTimeout;
            }
            std.time.sleep(1_000); // 1us
        }
        const start_ns = std.time.nanoTimestamp();

        // Wait for echo to go LOW (end of return pulse)
        timeout = 0;
        while (self.hal_ctx.gpio_echo.read()) {
            timeout += 1;
            if (timeout >= TIMEOUT_ITERATIONS) {
                // Echo stayed high: object too far or sensor error
                return MeasurementError.EchoTimeout;
            }
            std.time.sleep(1_000); // 1us
        }
        const end_ns = std.time.nanoTimestamp();

        // Calculate distance: speed of sound = 34300 cm/s, round trip so /2
        const duration_ns = end_ns - start_ns;
        const duration_us: f64 = @as(f64, @floatFromInt(duration_ns)) / 1000.0;
        const distance_cm: f32 = @floatCast(duration_us * 0.01715);
        self.last_distance_cm = std.math.clamp(distance_cm, 0.0, MAX_DISTANCE_CM);
        return self.last_distance_cm;
    }
};

test "Ultrasonic simulation returns valid range" {
    if (!cfg.sim) return;
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var ultra = Ultrasonic.init(&ctx);
    const d = ultra.readDistance();
    try std.testing.expect(d >= 5.0 and d <= 200.0);
}

test "Ultrasonic simulation returns different values" {
    if (!cfg.sim) return;
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var ultra = Ultrasonic.init(&ctx);
    const d1 = ultra.readDistance();
    const d2 = ultra.readDistance();
    try std.testing.expect(d1 != d2);
}
