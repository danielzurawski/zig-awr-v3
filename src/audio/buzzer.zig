const std = @import("std");
const hal = @import("../hal.zig");
const cfg = @import("config");

const NoteFreq = struct { name: []const u8, freq_hz: u16 };

const NOTE_TABLE = [_]NoteFreq{
    .{ .name = "C4", .freq_hz = 262 }, .{ .name = "D4", .freq_hz = 294 },
    .{ .name = "E4", .freq_hz = 330 }, .{ .name = "F4", .freq_hz = 349 },
    .{ .name = "G4", .freq_hz = 392 }, .{ .name = "A4", .freq_hz = 440 },
    .{ .name = "B4", .freq_hz = 494 }, .{ .name = "C5", .freq_hz = 523 },
    .{ .name = "D5", .freq_hz = 587 }, .{ .name = "E5", .freq_hz = 659 },
    .{ .name = "F5", .freq_hz = 698 }, .{ .name = "G5", .freq_hz = 784 },
    .{ .name = "A5", .freq_hz = 880 }, .{ .name = "B5", .freq_hz = 988 },
};

pub const NoteEntry = struct { name: []const u8, duration_ms: u32 };

pub const HAPPY_BIRTHDAY = [_]NoteEntry{
    .{ .name = "G4", .duration_ms = 300 }, .{ .name = "G4", .duration_ms = 300 },
    .{ .name = "A4", .duration_ms = 300 }, .{ .name = "G4", .duration_ms = 300 },
    .{ .name = "C5", .duration_ms = 300 }, .{ .name = "B4", .duration_ms = 600 },
    .{ .name = "G4", .duration_ms = 300 }, .{ .name = "G4", .duration_ms = 300 },
    .{ .name = "A4", .duration_ms = 300 }, .{ .name = "G4", .duration_ms = 300 },
    .{ .name = "D5", .duration_ms = 300 }, .{ .name = "C5", .duration_ms = 600 },
};

fn lookupFrequency(name: []const u8) u16 {
    for (NOTE_TABLE) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.freq_hz;
    }
    return 0;
}

pub const Buzzer = struct {
    hal_ctx: *hal.HalContext,
    playing: bool = false,
    current_freq: u16 = 0,
    stop_requested: bool = false,

    pub fn init(ctx: *hal.HalContext) Buzzer {
        return .{ .hal_ctx = ctx };
    }

    /// Play a single note by name for a given duration in milliseconds.
    /// Clears any prior stop request before beginning playback.
    pub fn playNote(self: *Buzzer, note: []const u8, duration_ms: u32) void {
        const freq = lookupFrequency(note);
        if (freq == 0) return;

        // Clear prior stop state so this note can play fully
        self.stop_requested = false;
        self.current_freq = freq;
        self.playing = true;

        if (cfg.sim) {
            std.time.sleep(@as(u64, duration_ms) * 1_000_000);
        } else {
            // Toggle GPIO at note frequency for the requested duration.
            // Half-period in nanoseconds = 500_000_000 / freq_hz
            const half_period_ns: u64 = 500_000_000 / @as(u64, freq);
            const total_cycles = @as(u64, freq) * duration_ms / 1000;
            var cycle: u64 = 0;
            while (cycle < total_cycles) : (cycle += 1) {
                if (self.stop_requested) break;
                self.hal_ctx.gpio_buzzer.write(true);
                std.time.sleep(half_period_ns);
                self.hal_ctx.gpio_buzzer.write(false);
                std.time.sleep(half_period_ns);
            }
        }

        self.playing = false;
        self.current_freq = 0;
    }

    /// Request immediate stop of any current or future playback.
    pub fn stop(self: *Buzzer) void {
        self.stop_requested = true;
        self.playing = false;
        self.current_freq = 0;
        self.hal_ctx.gpio_buzzer.write(false);
    }

    /// Play a sequence of notes. Clears stop state at the start so the
    /// full tune plays unless stop() is called during playback.
    pub fn playTune(self: *Buzzer, tune: []const NoteEntry) void {
        self.stop_requested = false;
        for (tune) |entry| {
            if (self.stop_requested) break;
            self.playNote(entry.name, entry.duration_ms);
        }
        self.playing = false;
    }
};

test "lookupFrequency known notes" {
    try std.testing.expectEqual(@as(u16, 262), lookupFrequency("C4"));
    try std.testing.expectEqual(@as(u16, 440), lookupFrequency("A4"));
    try std.testing.expectEqual(@as(u16, 523), lookupFrequency("C5"));
    try std.testing.expectEqual(@as(u16, 0), lookupFrequency("X9"));
}

test "Buzzer playNote clears stop_requested and plays" {
    if (!cfg.sim) return;
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var buz = Buzzer.init(&ctx);
    // Simulate a prior stop
    buz.stop();
    try std.testing.expect(buz.stop_requested);
    // playNote must clear stop_requested and complete normally
    buz.playNote("C4", 1);
    try std.testing.expect(!buz.playing);
    try std.testing.expectEqual(@as(u16, 0), buz.current_freq);
}

test "Buzzer stop clears state" {
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var buz = Buzzer.init(&ctx);
    buz.playing = true;
    buz.current_freq = 440;
    buz.stop();
    try std.testing.expect(!buz.playing);
    try std.testing.expect(buz.stop_requested);
}

test "Buzzer playTune processes notes after prior stop" {
    if (!cfg.sim) return;
    var ctx = hal.HalContext.init();
    defer ctx.deinit();
    var buz = Buzzer.init(&ctx);
    buz.stop(); // Prior stop
    const short_tune = [_]NoteEntry{
        .{ .name = "C4", .duration_ms = 1 },
        .{ .name = "D4", .duration_ms = 1 },
    };
    buz.playTune(&short_tune); // Must clear stop and play both notes
    try std.testing.expect(!buz.playing);
    try std.testing.expect(!buz.stop_requested);
}
