const std = @import("std");
const cfg = @import("config");

pub const Response = struct {
    status: []const u8 = "ok",
    title: []const u8 = "",
    data: ?[4][]const u8 = null,
};

pub fn formatResponse(buf: []u8, resp: Response) ![]u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    try writer.writeAll("{\"status\":\"");
    try writer.writeAll(resp.status);
    try writer.writeAll("\",\"title\":\"");
    try writer.writeAll(resp.title);
    try writer.writeAll("\",\"data\":");
    if (resp.data) |data| {
        try writer.writeAll("[\"");
        try writer.writeAll(data[0]);
        try writer.writeAll("\",\"");
        try writer.writeAll(data[1]);
        try writer.writeAll("\",\"");
        try writer.writeAll(data[2]);
        try writer.writeAll("\",\"");
        try writer.writeAll(data[3]);
        try writer.writeAll("\"]");
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}");

    return stream.getWritten();
}

pub fn isMovementCmd(cmd: []const u8) bool {
    const cmds = [_][]const u8{ "forward", "backward", "left", "right", "rotate-left", "rotate-right" };
    for (cmds) |c| {
        if (std.mem.eql(u8, cmd, c)) return true;
    }
    return false;
}

pub fn isStopCmd(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "DS") or std.mem.eql(u8, cmd, "TS") or std.mem.eql(u8, cmd, "UDstop");
}

pub fn isTiltCmd(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "up") or std.mem.eql(u8, cmd, "down");
}

pub fn isFunctionCmd(cmd: []const u8) bool {
    const cmds = [_][]const u8{
        "findColor",       "motionGet",    "stopCV", "automatic", "automaticOff",
        "trackLine",       "trackLineOff", "police", "policeOff", "keepDistance",
        "keepDistanceOff", "CVFL",
    };
    for (cmds) |c| {
        if (std.mem.eql(u8, cmd, c)) return true;
    }
    return false;
}

pub fn isAudioCmd(cmd: []const u8) bool {
    return std.mem.startsWith(u8, cmd, "tone ") or std.mem.startsWith(u8, cmd, "tune ");
}

pub fn isLightEffectCmd(cmd: []const u8) bool {
    const cmds = [_][]const u8{
        "lights_breath_blue", "lights_rainbow", "lights_flowing", "lights_off",
    };
    for (cmds) |c| {
        if (std.mem.eql(u8, cmd, c)) return true;
    }
    return false;
}

pub fn isSwitchCmd(cmd: []const u8) bool {
    return std.mem.startsWith(u8, cmd, "Switch_");
}

pub fn isServoCmd(cmd: []const u8) bool {
    return std.mem.startsWith(u8, cmd, "Si") or std.mem.startsWith(u8, cmd, "PWM");
}

pub fn isSpeedCmd(cmd: []const u8) bool {
    return std.mem.startsWith(u8, cmd, "wsB ");
}

pub fn isJsonStr(data: []const u8) bool {
    if (data.len < 2) return false;
    return data[0] == '{' and data[data.len - 1] == '}';
}

test "formatResponse basic" {
    var buf: [512]u8 = undefined;
    const resp = Response{};
    const out = try formatResponse(&buf, resp);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"data\":null") != null);
}

test "formatResponse with data" {
    var buf: [512]u8 = undefined;
    const resp = Response{
        .title = "get_info",
        .data = .{ "45.2", "12.3", "55.1", "80" },
    };
    const out = try formatResponse(&buf, resp);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\":\"get_info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[\"45.2\"") != null);
}

test "command detection" {
    try std.testing.expect(isMovementCmd("forward"));
    try std.testing.expect(isMovementCmd("rotate-left"));
    try std.testing.expect(!isMovementCmd("up"));
    try std.testing.expect(isStopCmd("DS"));
    try std.testing.expect(isTiltCmd("up"));
    try std.testing.expect(isFunctionCmd("findColor"));
    try std.testing.expect(isAudioCmd("tone C5 160"));
    try std.testing.expect(isAudioCmd("tune baby_shark"));
    try std.testing.expect(isLightEffectCmd("lights_rainbow"));
    try std.testing.expect(isSwitchCmd("Switch_1_on"));
    try std.testing.expect(isServoCmd("SiLeft 0"));
    try std.testing.expect(isServoCmd("PWMINIT"));
    try std.testing.expect(isSpeedCmd("wsB 50"));
    try std.testing.expect(isJsonStr("{\"title\":\"test\"}"));
}
