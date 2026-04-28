const std = @import("std");
const hal = @import("../hal.zig");

pub const MAX_LEDS: usize = 16;
pub const LedMode = enum { none, breath, police, rainbow, flowing };
pub const Color = struct { r: u8, g: u8, b: u8 };

// WS2812 SPI encoding constants (GRB byte order)
const BIT_1: u8 = 0xF8; // ~0.78us HIGH, ~0.39us LOW
const BIT_0: u8 = 0x80; // ~0.16us HIGH, ~1.09us LOW

pub const Ws2812 = struct {
    hal_ctx: *hal.HalContext,
    leds: [MAX_LEDS]Color = [_]Color{.{ .r = 0, .g = 0, .b = 0 }} ** MAX_LEDS,
    count: u8 = 8,
    brightness: u8 = 255,
    mode: LedMode = .none,
    breath_color: Color = .{ .r = 0, .g = 0, .b = 0 },
    breath_step: u8 = 0,
    breath_rising: bool = true,
    rainbow_offset: u8 = 0,
    flowing_pos: u8 = 0,
    flowing_color: Color = .{ .r = 0, .g = 0, .b = 0 },

    pub fn init(ctx: *hal.HalContext) Ws2812 {
        return .{ .hal_ctx = ctx };
    }

    pub fn setAll(self: *Ws2812, color: Color) void {
        for (0..self.count) |i| {
            self.leds[i] = color;
        }
    }

    pub fn setPixel(self: *Ws2812, index: u8, color: Color) void {
        if (index < self.count) {
            self.leds[index] = color;
        }
    }

    /// Encode LED data to WS2812 SPI format and transmit
    pub fn show(self: *Ws2812) void {
        var spi_buf: [MAX_LEDS * 3 * 8]u8 = undefined;
        var pos: usize = 0;

        for (0..self.count) |i| {
            const r: u8 = @intCast(@as(u16, self.leds[i].r) * self.brightness / 255);
            const g: u8 = @intCast(@as(u16, self.leds[i].g) * self.brightness / 255);
            const b: u8 = @intCast(@as(u16, self.leds[i].b) * self.brightness / 255);

            // GRB byte order
            const bytes = [3]u8{ g, r, b };
            for (bytes) |byte| {
                var bit: u4 = 8;
                while (bit > 0) {
                    bit -= 1;
                    spi_buf[pos] = if ((byte >> @intCast(bit)) & 1 == 1) BIT_1 else BIT_0;
                    pos += 1;
                }
            }
        }
        self.hal_ctx.spi.transfer(spi_buf[0..pos]);
    }

    // ── Effect modes ─────────────────────────────────────────────

    pub fn breath(self: *Ws2812, r: u8, g: u8, b: u8) void {
        self.mode = .breath;
        self.breath_color = .{ .r = r, .g = g, .b = b };
        self.breath_step = 0;
        self.breath_rising = true;
    }

    /// Advance breath animation by one step
    pub fn breathTick(self: *Ws2812) void {
        if (self.mode != .breath) return;
        const steps: u8 = 10;
        const scale: f32 = @as(f32, @floatFromInt(self.breath_step)) / @as(f32, @floatFromInt(steps));
        const r: u8 = @intFromFloat(@as(f32, @floatFromInt(self.breath_color.r)) * scale);
        const g: u8 = @intFromFloat(@as(f32, @floatFromInt(self.breath_color.g)) * scale);
        const b: u8 = @intFromFloat(@as(f32, @floatFromInt(self.breath_color.b)) * scale);
        self.setAll(.{ .r = r, .g = g, .b = b });
        self.show();

        if (self.breath_rising) {
            if (self.breath_step >= steps) self.breath_rising = false else self.breath_step += 1;
        } else {
            if (self.breath_step == 0) self.breath_rising = true else self.breath_step -= 1;
        }
    }

    pub fn police(self: *Ws2812) void {
        self.mode = .police;
    }

    /// Execute one police flash: even phase=blue, odd phase=red
    pub fn policeTick(self: *Ws2812, phase: u8) void {
        if (self.mode != .police) return;
        if (phase % 2 == 0) {
            self.setAll(.{ .r = 0, .g = 0, .b = 255 });
        } else {
            self.setAll(.{ .r = 255, .g = 0, .b = 0 });
        }
        self.show();
    }

    pub fn rainbow(self: *Ws2812) void {
        self.mode = .rainbow;
        self.rainbow_offset = 0;
    }

    /// Advance rainbow animation: each LED gets a hue offset from the color wheel
    pub fn rainbowTick(self: *Ws2812) void {
        if (self.mode != .rainbow) return;
        for (0..self.count) |i| {
            const wheel_pos: u8 = @truncate(@as(usize, self.rainbow_offset) +% (i * 255 / self.count));
            self.leds[i] = wheelColor(wheel_pos);
        }
        self.show();
        self.rainbow_offset +%= 3;
    }

    pub fn flowing(self: *Ws2812, r: u8, g: u8, b: u8) void {
        self.mode = .flowing;
        self.flowing_color = .{ .r = r, .g = g, .b = b };
        self.flowing_pos = 0;
    }

    /// Advance flowing animation: one lit LED chases along the strip
    pub fn flowingTick(self: *Ws2812) void {
        if (self.mode != .flowing) return;
        self.setAll(.{ .r = 0, .g = 0, .b = 0 });
        self.setPixel(self.flowing_pos, self.flowing_color);
        self.show();
        self.flowing_pos = if (self.flowing_pos + 1 >= self.count) 0 else self.flowing_pos + 1;
    }

    pub fn off(self: *Ws2812) void {
        self.mode = .none;
        self.setAll(.{ .r = 0, .g = 0, .b = 0 });
        self.show();
    }

    /// Color wheel: input 0-255, outputs RGB cycling through R→G→B→R
    fn wheelColor(pos: u8) Color {
        if (pos < 85) {
            return .{ .r = 255 - pos * 3, .g = pos * 3, .b = 0 };
        } else if (pos < 170) {
            const p = pos - 85;
            return .{ .r = 0, .g = 255 - p * 3, .b = p * 3 };
        } else {
            const p = pos - 170;
            return .{ .r = p * 3, .g = 0, .b = 255 - p * 3 };
        }
    }
};

test "Ws2812 setAll and show" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var leds = Ws2812.init(&ctx);
    leds.setAll(.{ .r = 255, .g = 0, .b = 128 });
    leds.show();
    try std.testing.expectEqual(@as(u8, 255), leds.leds[0].r);
    try std.testing.expectEqual(@as(u8, 128), leds.leds[7].b);
}

test "Ws2812 breath mode ticks" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var leds = Ws2812.init(&ctx);
    leds.breath(100, 50, 200);
    try std.testing.expectEqual(LedMode.breath, leds.mode);
    for (0..5) |_| leds.breathTick();
    try std.testing.expect(leds.breath_step > 0);
}

test "Ws2812 police mode ticks" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var leds = Ws2812.init(&ctx);
    leds.police();
    leds.policeTick(0);
    try std.testing.expectEqual(@as(u8, 255), leds.leds[0].b);
    leds.policeTick(1);
    try std.testing.expectEqual(@as(u8, 255), leds.leds[0].r);
}

test "Ws2812 rainbow mode produces different colors per LED" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var leds = Ws2812.init(&ctx);
    leds.rainbow();
    leds.rainbowTick();
    // Adjacent LEDs should have different colors
    const c0 = leds.leds[0];
    const c4 = leds.leds[4];
    try std.testing.expect(c0.r != c4.r or c0.g != c4.g or c0.b != c4.b);
}

test "Ws2812 flowing mode advances position" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var leds = Ws2812.init(&ctx);
    leds.flowing(255, 128, 0);
    leds.flowingTick();
    try std.testing.expectEqual(@as(u8, 255), leds.leds[0].r); // First tick lights pos 0
    try std.testing.expectEqual(@as(u8, 1), leds.flowing_pos); // Pos advances to 1
    leds.flowingTick();
    try std.testing.expectEqual(@as(u8, 0), leds.leds[0].r); // Pos 0 now dark
    try std.testing.expectEqual(@as(u8, 255), leds.leds[1].r); // Pos 1 lit
}

test "Ws2812 off clears all" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var leds = Ws2812.init(&ctx);
    leds.setAll(.{ .r = 255, .g = 255, .b = 255 });
    leds.off();
    try std.testing.expectEqual(@as(u8, 0), leds.leds[0].r);
    try std.testing.expectEqual(LedMode.none, leds.mode);
}
