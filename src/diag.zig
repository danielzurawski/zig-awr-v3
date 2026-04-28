const std = @import("std");
const cfg = @import("config");

const hal = @import("hal.zig");
const motor_mod = @import("motor/driver.zig");
const servo_mod = @import("servo/controller.zig");
const ultra_mod = @import("sensor/ultrasonic.zig");
const battery_mod = @import("sensor/battery.zig");
const line_mod = @import("sensor/line_tracker.zig");
const led_mod = @import("led/ws2812.zig");
const buzzer_mod = @import("audio/buzzer.zig");

const LED0_ON_L: u8 = 0x06;
const MOTOR_PWM_CHANNELS = [_]u8{ 15, 14, 12, 13, 11, 10, 8, 9 };

const DiagSummary = struct {
    pass: usize = 0,
    fail: usize = 0,

    fn record(self: *DiagSummary, ok: bool) void {
        if (ok) self.pass += 1 else self.fail += 1;
    }
};

fn marker(
    writer: anytype,
    summary: *DiagSummary,
    name: []const u8,
    ok: bool,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    summary.record(ok);
    try writer.print("MARKER {s} {s} ", .{ name, if (ok) "ok" else "fail" });
    try writer.print(fmt, args);
    try writer.writeByte('\n');
}

fn access(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn writePcaChannelZero(ctx: *hal.HalContext, channel: u8) !void {
    const reg = LED0_ON_L + @as(u8, 4) * channel;
    try ctx.i2c_pca9685.writeReg(reg, &[_]u8{ 0, 0, 0, 0 });
}

fn readPcaReg(ctx: *hal.HalContext, reg: u8) !u8 {
    return try ctx.i2c_pca9685.readReg(reg);
}

fn testDevicePaths(writer: anytype, summary: *DiagSummary) !void {
    try marker(writer, summary, "dev_i2c_1", access("/dev/i2c-1"), "path=/dev/i2c-1", .{});
    try marker(writer, summary, "dev_spidev0_0", access("/dev/spidev0.0"), "path=/dev/spidev0.0", .{});
    try marker(writer, summary, "dev_gpiomem", access("/dev/gpiomem"), "path=/dev/gpiomem", .{});
}

fn testI2cAndMotorStop(writer: anytype, summary: *DiagSummary, ctx: *hal.HalContext) !void {
    const mode1 = ctx.i2c_pca9685.readReg(0x00) catch |err| {
        try marker(writer, summary, "i2c_pca9685", false, "addr=0x5f err={s}", .{@errorName(err)});
        return;
    };
    try marker(writer, summary, "i2c_pca9685", true, "addr=0x5f mode1=0x{x:0>2}", .{mode1});

    var motor = motor_mod.MotorDriver.init(ctx);
    motor.stop();

    var zero_writes_ok = true;
    for (MOTOR_PWM_CHANNELS) |channel| {
        writePcaChannelZero(ctx, channel) catch {
            zero_writes_ok = false;
        };
    }
    const off_l = readPcaReg(ctx, LED0_ON_L + 4 * MOTOR_PWM_CHANNELS[0] + 2) catch 255;
    try marker(
        writer,
        summary,
        "motor_safe_stop",
        zero_writes_ok and off_l == 0,
        "channels=8,9,10,11,12,13,14,15 off_l_ch15=0x{x:0>2} no_drive=true",
        .{off_l},
    );
}

fn testBattery(writer: anytype, summary: *DiagSummary, ctx: *hal.HalContext) !void {
    var battery = battery_mod.BatteryMonitor.init(ctx);
    battery.read();
    const ok = battery.voltage > 0.5 and battery.voltage < 12.6;
    try marker(
        writer,
        summary,
        "battery_ads7830",
        ok,
        "addr=0x48 voltage={d:.2} percentage={d}",
        .{ battery.voltage, battery.percentage },
    );
}

fn testUltrasonic(writer: anytype, summary: *DiagSummary, ctx: *hal.HalContext) !void {
    var ultrasonic = ultra_mod.Ultrasonic.init(ctx);
    var samples: [5]f32 = undefined;
    var valid: usize = 0;
    for (&samples) |*sample| {
        sample.* = ultrasonic.readDistance();
        if (sample.* >= 2.0 and sample.* <= 200.0) valid += 1;
        std.time.sleep(60_000_000);
    }
    try marker(
        writer,
        summary,
        "ultrasonic_hcsr04",
        valid >= 3,
        "samples_cm={d:.1},{d:.1},{d:.1},{d:.1},{d:.1} valid={d}/5",
        .{ samples[0], samples[1], samples[2], samples[3], samples[4], valid },
    );
}

fn testLineTracker(writer: anytype, summary: *DiagSummary, ctx: *hal.HalContext) !void {
    var line = line_mod.LineTracker.init(ctx);
    line.read();
    try marker(
        writer,
        summary,
        "line_tracker",
        true,
        "left={} middle={} right={} bitmask=0b{b:0>3}",
        .{ line.left, line.middle, line.right, line.status() },
    );
}

fn testDiscreteLeds(writer: anytype, summary: *DiagSummary, ctx: *hal.HalContext) !void {
    const pins = [_]struct {
        name: []const u8,
        pin: *hal.GpioPin,
    }{
        .{ .name = "led_gpio_1", .pin = &ctx.gpio_led1 },
        .{ .name = "led_gpio_2", .pin = &ctx.gpio_led2 },
        .{ .name = "led_gpio_3", .pin = &ctx.gpio_led3 },
    };

    for (pins) |entry| {
        entry.pin.write(true);
        std.time.sleep(120_000_000);
        const on_read = entry.pin.read();
        entry.pin.write(false);
        std.time.sleep(80_000_000);
        const off_read = entry.pin.read();
        try marker(writer, summary, entry.name, on_read and !off_read, "on_read={} off_read={}", .{ on_read, off_read });
    }
}

fn testWs2812(writer: anytype, summary: *DiagSummary, ctx: *hal.HalContext) !void {
    var leds = led_mod.Ws2812.init(ctx);
    leds.setAll(.{ .r = 0, .g = 0, .b = 64 });
    leds.show();
    std.time.sleep(250_000_000);
    leds.off();
    try marker(writer, summary, "ws2812_spi", true, "count={d} marker=blue_then_off", .{leds.count});
}

fn testBuzzer(writer: anytype, summary: *DiagSummary, ctx: *hal.HalContext) !void {
    var buzzer = buzzer_mod.Buzzer.init(ctx);
    buzzer.playNote("C5", 120);
    buzzer.stop();
    try marker(writer, summary, "buzzer_gpio18", true, "note=C5 duration_ms=120", .{});
}

fn testServo(writer: anytype, summary: *DiagSummary, ctx: *hal.HalContext) !void {
    var servo = servo_mod.ServoController.init(ctx);
    servo.moveAngle(0, 0);
    std.time.sleep(200_000_000);
    servo.singleServo(0, 1, 2);
    std.time.sleep(150_000_000);
    servo.stopWiggle();
    servo.moveAngle(0, 0);
    try marker(
        writer,
        summary,
        "servo_camera_tilt",
        servo.current_pos[0] >= servo.min_pos[0] and servo.current_pos[0] <= servo.max_pos[0],
        "channel=0 pos={d} bounded_nudge=true",
        .{servo.current_pos[0]},
    );
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var summary = DiagSummary{};

    try stdout.print("AWR_V3_ZIG_DIAG_START sim={} motor={} servo={} ultrasonic={} line={} battery={} led={} buzzer={}\n", .{
        cfg.sim,
        cfg.motor,
        cfg.servo,
        cfg.ultrasonic,
        cfg.line_tracker,
        cfg.battery,
        cfg.led,
        cfg.buzzer,
    });

    try testDevicePaths(stdout, &summary);

    var ctx = hal.HalContext.init();
    defer ctx.deinit();

    try testI2cAndMotorStop(stdout, &summary, &ctx);
    if (cfg.battery) try testBattery(stdout, &summary, &ctx);
    if (cfg.ultrasonic) try testUltrasonic(stdout, &summary, &ctx);
    if (cfg.line_tracker) try testLineTracker(stdout, &summary, &ctx);
    try testDiscreteLeds(stdout, &summary, &ctx);
    if (cfg.led) try testWs2812(stdout, &summary, &ctx);
    if (cfg.buzzer) try testBuzzer(stdout, &summary, &ctx);
    if (cfg.servo) try testServo(stdout, &summary, &ctx);

    var motor = motor_mod.MotorDriver.init(&ctx);
    motor.stop();
    ctx.gpio_led1.write(false);
    ctx.gpio_led2.write(false);
    ctx.gpio_led3.write(false);
    if (cfg.led) {
        var leds = led_mod.Ws2812.init(&ctx);
        leds.off();
    }
    if (cfg.buzzer) {
        var buzzer = buzzer_mod.Buzzer.init(&ctx);
        buzzer.stop();
    }

    try stdout.print("AWR_V3_ZIG_DIAG_SUMMARY pass={d} fail={d}\n", .{ summary.pass, summary.fail });
    if (summary.fail > 0) return error.DiagnosticsFailed;
}
