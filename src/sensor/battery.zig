const std = @import("std");
const hal = @import("../hal.zig");
const cfg = @import("config");

const FULL_VOLTAGE: f32 = 8.4;
const WARNING_THRESHOLD: f32 = 6.0;
const ADC_VREF: f32 = 5.2;
const R15: f32 = 3000.0;
const R17: f32 = 1000.0;
const DIVISION_RATIO: f32 = R17 / (R15 + R17); // 0.25

/// ADS7830 command byte structure:
/// Bit 7: single-ended=1, Bit 6-4: channel select, Bit 3-2: power mode, Bit 1-0: unused
/// For single-ended channel 0: 0b10000100 = 0x84
const ADS7830_BASE_CMD: u8 = 0x84;

pub const BatteryMonitor = struct {
    hal_ctx: *hal.HalContext,
    voltage: f32 = 7.4,
    percentage: u8 = 75,
    sim_rng: if (cfg.sim) std.Random.Xoshiro256 else void,

    pub fn init(ctx: *hal.HalContext) BatteryMonitor {
        return .{
            .hal_ctx = ctx,
            .sim_rng = if (cfg.sim) std.Random.Xoshiro256.init(12345) else {},
        };
    }

    pub fn read(self: *BatteryMonitor) void {
        if (cfg.sim) {
            const r = self.sim_rng.random().float(f32);
            self.voltage = 6.5 + r * 1.9;
        } else {
            self.readReal();
        }
        self.updatePercentage();
    }

    /// Read battery voltage from ADS7830 ADC via I2C.
    /// The ADS7830 uses a command-byte protocol (not register-based):
    /// 1. Send the command byte selecting channel and mode
    /// 2. Read back one byte containing the 8-bit ADC result
    fn readReal(self: *BatteryMonitor) void {
        const channel: u8 = 0;
        // Build command byte: base | channel_select_bits
        const channel_bits = ((channel << 2) | (channel >> 1)) & 0x07;
        const cmd_byte = ADS7830_BASE_CMD | (channel_bits << 4);

        // Send command byte as a raw I2C write (not a register write)
        self.hal_ctx.i2c_ads7830.rawWrite(&[_]u8{cmd_byte}) catch return;

        // Read back the 8-bit ADC result
        const adc_val = self.hal_ctx.i2c_ads7830.rawRead() catch return;

        // Convert: ADC → voltage at divider midpoint → actual battery voltage
        const a0_voltage = @as(f32, @floatFromInt(adc_val)) / 255.0 * ADC_VREF;
        self.voltage = a0_voltage / DIVISION_RATIO;
    }

    fn updatePercentage(self: *BatteryMonitor) void {
        const pct_raw = (self.voltage - WARNING_THRESHOLD) / (FULL_VOLTAGE - WARNING_THRESHOLD) * 100.0;
        self.percentage = @intFromFloat(std.math.clamp(pct_raw, 0.0, 100.0));
    }

    pub fn isLow(self: *const BatteryMonitor) bool {
        return self.voltage < WARNING_THRESHOLD;
    }

    pub fn getPercentage(self: *const BatteryMonitor) u8 {
        return self.percentage;
    }
};

test "BatteryMonitor simulation produces valid values" {
    if (!cfg.sim) return;
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var bat = BatteryMonitor.init(&ctx);
    bat.read();
    try std.testing.expect(bat.voltage >= 6.5 and bat.voltage <= 8.4);
    try std.testing.expect(bat.percentage <= 100);
}

test "BatteryMonitor percentage at full charge" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var bat = BatteryMonitor.init(&ctx);
    bat.voltage = FULL_VOLTAGE;
    bat.updatePercentage();
    try std.testing.expectEqual(@as(u8, 100), bat.percentage);
}

test "BatteryMonitor percentage at threshold" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var bat = BatteryMonitor.init(&ctx);
    bat.voltage = WARNING_THRESHOLD;
    bat.updatePercentage();
    try std.testing.expectEqual(@as(u8, 0), bat.percentage);
}

test "BatteryMonitor low detection" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var bat = BatteryMonitor.init(&ctx);
    bat.voltage = 5.5;
    try std.testing.expect(bat.isLow());
    bat.voltage = 7.0;
    try std.testing.expect(!bat.isLow());
}
