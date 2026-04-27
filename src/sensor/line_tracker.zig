const std = @import("std");
const hal = @import("../hal.zig");
const cfg = @import("config");

pub const LineTracker = struct {
    hal_ctx: *hal.HalContext,
    left: bool = false,
    middle: bool = false,
    right: bool = false,

    pub fn init(ctx: *hal.HalContext) LineTracker {
        return .{ .hal_ctx = ctx };
    }

    pub fn read(self: *LineTracker) void {
        if (cfg.sim) {
            // Simulated: static values
            self.left = false;
            self.middle = true;
            self.right = false;
        } else {
            self.left = self.hal_ctx.gpio_line_l.read();
            self.middle = self.hal_ctx.gpio_line_m.read();
            self.right = self.hal_ctx.gpio_line_r.read();
        }
    }

    pub fn status(self: *const LineTracker) u3 {
        return (@as(u3, @intFromBool(self.left)) << 2) |
            (@as(u3, @intFromBool(self.middle)) << 1) |
            @as(u3, @intFromBool(self.right));
    }
};

test "LineTracker status encoding" {
    var ctx = hal.HalContext.init();
    var lt = LineTracker.init(&ctx);
    lt.left = true;
    lt.middle = false;
    lt.right = true;
    try std.testing.expectEqual(@as(u3, 0b101), lt.status());
}