const std = @import("std");
const cfg = @import("config");
const protocol = @import("protocol.zig");
const main_mod = @import("../main.zig");
const grid_mod = @import("../slam/occupancy_grid.zig");
const path_planner = @import("../slam/path_planner.zig");

var auth_user_buf: [64]u8 = undefined;
var auth_pass_buf: [64]u8 = undefined;
var auth_user: []const u8 = "";
var auth_pass: []const u8 = "";

// ── SLAM mapping thread state ────────────────────────────────────────
// Single global thread is fine: only one mapping loop should ever run
// because it owns exclusive access to the ultrasonic sensor.
var slam_thread: ?std.Thread = null;
var slam_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Approximate cm advanced per forward/backward command tick. Used for
/// dead-reckoning the robot pose on the occupancy grid. Conservative —
/// real travel depends on speed and tick duration, but this gives a
/// usable map without requiring wheel encoders.
const STEP_CM_PER_MOVE: f32 = 4.0;
/// Heading delta (radians) per rotate-left / rotate-right command.
const ROT_RAD_PER_TURN: f32 = 0.262; // ~15 degrees

fn loadCredentials() void {
    if (std.posix.getenv("AWR_WS_USER")) |user| {
        const len = @min(user.len, auth_user_buf.len);
        @memcpy(auth_user_buf[0..len], user[0..len]);
        auth_user = auth_user_buf[0..len];
    }
    if (std.posix.getenv("AWR_WS_PASS")) |pass| {
        const len = @min(pass.len, auth_pass_buf.len);
        @memcpy(auth_pass_buf[0..len], pass[0..len]);
        auth_pass = auth_pass_buf[0..len];
    }
}

var sim_seed: u64 = 12345;
fn simRand() f64 {
    sim_seed = sim_seed *% 6364136223846793005 +% 1442695040888963407;
    return @as(f64, @floatFromInt(sim_seed >> 33)) / @as(f64, @floatFromInt(@as(u64, 1) << 31));
}

var robot_mutex = std.Thread.Mutex{};

const HttpHeaders = struct {
    is_upgrade: bool = false,
    ws_key: ?[]const u8 = null,
    is_get: bool = false,
};

fn readHttpUpgrade(conn: std.net.Stream, buf: []u8) !HttpHeaders {
    var total: usize = 0;
    while (total < buf.len - 1) {
        const n = try conn.read(buf[total .. total + 1]);
        if (n == 0) return error.ConnectionClosed;
        total += n;
        if (total >= 4 and std.mem.eql(u8, buf[total - 4 .. total], "\r\n\r\n")) break;
    }
    const request_bytes = buf[0..total];
    var result = HttpHeaders{};
    var lines = std.mem.splitSequence(u8, request_bytes, "\r\n");
    if (lines.next()) |first_line| {
        if (std.mem.startsWith(u8, first_line, "GET ")) result.is_get = true;
    }
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.indexOfScalar(u8, line, ':')) |ci| {
            const name = std.mem.trim(u8, line[0..ci], " ");
            const value = std.mem.trim(u8, line[ci + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "upgrade") and std.ascii.eqlIgnoreCase(value, "websocket")) {
                result.is_upgrade = true;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
                result.ws_key = value;
            }
        }
    }
    return result;
}

fn handleConnection(conn: std.net.Stream, robot: *main_mod.RobotState) void {
    var http_buf: [4096]u8 = undefined;
    const headers = readHttpUpgrade(conn, &http_buf) catch return;
    if (!headers.is_upgrade or headers.ws_key == null) {
        conn.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nAWR-V3 Zig Firmware WebSocket Server") catch {};
        return;
    }
    var accept_buf: [28]u8 = undefined;
    const accept_key = computeAcceptKey(headers.ws_key.?, &accept_buf);
    var hdr: [256]u8 = undefined;
    var hs = std.io.fixedBufferStream(&hdr);
    const hw = hs.writer();
    hw.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ") catch return;
    hw.writeAll(accept_key) catch return;
    hw.writeAll("\r\n\r\n") catch return;
    conn.writeAll(hs.getWritten()) catch return;

    var authenticated = false;
    while (true) {
        var frame_buf: [4096]u8 = undefined;
        const msg = readWsFrame(conn, &frame_buf) catch break;
        if (msg.len == 0) continue;

        if (!authenticated) {
            if (std.mem.indexOf(u8, msg, ":")) |_| {
                var iter = std.mem.splitScalar(u8, msg, ':');
                const user = iter.next() orelse "";
                const pass = iter.next() orelse "";
                if (std.mem.eql(u8, user, auth_user) and std.mem.eql(u8, pass, auth_pass)) {
                    authenticated = true;
                    sendWsText(conn, "congratulation, you have connect with server\r\nnow, you can do something else") catch break;
                } else {
                    sendWsText(conn, "sorry, the username or password is wrong, please submit again") catch break;
                }
            }
            continue;
        }

        // Each command branch uses an inner block scope for mutex lock+defer unlock,
        // ensuring the mutex is released when the block exits before continue/break.
        var resp_buf: [512]u8 = undefined;

        if (std.mem.eql(u8, msg, "get_info")) {
            const out = blk: {
                robot_mutex.lock();
                defer robot_mutex.unlock();
                var info_bufs: [4][16]u8 = undefined;
                const data = generateInfoData(&info_bufs, robot);
                const resp = protocol.Response{ .title = "get_info", .data = data };
                break :blk protocol.formatResponse(&resp_buf, resp) catch null;
            };
            if (out) |o| sendWsText(conn, o) catch break else continue;
            continue;
        }

        if (protocol.isMovementCmd(msg)) {
            {
                robot_mutex.lock();
                defer robot_mutex.unlock();
                robot.move_cmd = msg;
                robot.moving = true;
                if (cfg.motor) {
                    const turn = if (std.mem.eql(u8, msg, "forward")) "mid" else if (std.mem.eql(u8, msg, "backward")) "mid" else msg;
                    const dir: i8 = if (std.mem.eql(u8, msg, "backward")) -1 else 1;
                    robot.motor.move(robot.speed, dir, turn);
                }
                if (cfg.slam) {
                    if (std.mem.eql(u8, msg, "forward")) {
                        robot.slam_grid.applyTranslate(STEP_CM_PER_MOVE, 1);
                    } else if (std.mem.eql(u8, msg, "backward")) {
                        robot.slam_grid.applyTranslate(STEP_CM_PER_MOVE, -1);
                    } else if (std.mem.eql(u8, msg, "rotate-left") or std.mem.eql(u8, msg, "left")) {
                        robot.slam_grid.applyRotate(ROT_RAD_PER_TURN);
                    } else if (std.mem.eql(u8, msg, "rotate-right") or std.mem.eql(u8, msg, "right")) {
                        robot.slam_grid.applyRotate(-ROT_RAD_PER_TURN);
                    }
                }
            }
            const out = protocol.formatResponse(&resp_buf, .{}) catch continue;
            sendWsText(conn, out) catch break;
            continue;
        }

        if (protocol.isStopCmd(msg)) {
            {
                robot_mutex.lock();
                defer robot_mutex.unlock();
                if (std.mem.eql(u8, msg, "DS") or std.mem.eql(u8, msg, "TS")) {
                    robot.moving = false;
                    robot.move_cmd = "";
                    if (cfg.motor) robot.motor.stop();
                }
                if (std.mem.eql(u8, msg, "UDstop")) {
                    robot.tilt_cmd = "";
                    if (cfg.servo) robot.servo.stopWiggle();
                }
            }
            const out = protocol.formatResponse(&resp_buf, .{}) catch continue;
            sendWsText(conn, out) catch break;
            continue;
        }

        if (protocol.isTiltCmd(msg)) {
            {
                robot_mutex.lock();
                defer robot_mutex.unlock();
                robot.tilt_cmd = msg;
                if (cfg.servo) {
                    const dir: i8 = if (std.mem.eql(u8, msg, "up")) 1 else -1;
                    robot.servo.singleServo(0, dir, 7);
                }
            }
            const out = protocol.formatResponse(&resp_buf, .{}) catch continue;
            sendWsText(conn, out) catch break;
            continue;
        }

        if (protocol.isSpeedCmd(msg)) {
            {
                robot_mutex.lock();
                defer robot_mutex.unlock();
                if (msg.len > 4) {
                    const speed_str = std.mem.trimLeft(u8, msg[4..], " ");
                    robot.speed = std.fmt.parseInt(u8, speed_str, 10) catch robot.speed;
                }
            }
            const out = protocol.formatResponse(&resp_buf, .{}) catch continue;
            sendWsText(conn, out) catch break;
            continue;
        }

        if (protocol.isFunctionCmd(msg)) {
            {
                robot_mutex.lock();
                defer robot_mutex.unlock();
                dispatchFunction(msg, robot);
            }
            const out = protocol.formatResponse(&resp_buf, .{}) catch continue;
            sendWsText(conn, out) catch break;
            continue;
        }

        if (protocol.isAudioCmd(msg)) {
            {
                robot_mutex.lock();
                defer robot_mutex.unlock();
                dispatchAudio(msg, robot);
            }
            const out = protocol.formatResponse(&resp_buf, .{}) catch continue;
            sendWsText(conn, out) catch break;
            continue;
        }

        if (protocol.isLightEffectCmd(msg)) {
            {
                robot_mutex.lock();
                defer robot_mutex.unlock();
                dispatchLightEffect(msg, robot);
            }
            const out = protocol.formatResponse(&resp_buf, .{}) catch continue;
            sendWsText(conn, out) catch break;
            continue;
        }

        if (protocol.isSwitchCmd(msg)) {
            {
                robot_mutex.lock();
                defer robot_mutex.unlock();
                dispatchSwitch(msg, robot);
            }
            const out = protocol.formatResponse(&resp_buf, .{}) catch continue;
            sendWsText(conn, out) catch break;
            continue;
        }

        if (protocol.isServoCmd(msg)) {
            {
                robot_mutex.lock();
                defer robot_mutex.unlock();
                dispatchServo(msg, robot);
            }
            const out = protocol.formatResponse(&resp_buf, .{}) catch continue;
            sendWsText(conn, out) catch break;
            continue;
        }

        if (cfg.slam and protocol.isSlamCmd(msg)) {
            handleSlam(conn, msg, robot) catch break;
            continue;
        }

        if (protocol.isJsonStr(msg)) {
            const out = protocol.formatResponse(&resp_buf, .{}) catch continue;
            sendWsText(conn, out) catch break;
            continue;
        }

        const out = protocol.formatResponse(&resp_buf, .{}) catch continue;
        sendWsText(conn, out) catch break;
    }
}

// ── SLAM handlers ────────────────────────────────────────────────────

fn handleSlam(conn: std.net.Stream, msg: []const u8, robot: *main_mod.RobotState) !void {
    if (!cfg.slam) return;
    if (std.mem.eql(u8, msg, "mapping")) {
        startMappingThread(robot);
        var resp_buf: [256]u8 = undefined;
        const out = try protocol.formatResponse(&resp_buf, .{ .title = "mapping" });
        try sendWsText(conn, out);
        return;
    }
    if (std.mem.eql(u8, msg, "mappingOff")) {
        stopMappingThread(robot);
        var resp_buf: [256]u8 = undefined;
        const out = try protocol.formatResponse(&resp_buf, .{ .title = "mappingOff" });
        try sendWsText(conn, out);
        return;
    }
    if (std.mem.eql(u8, msg, "slam_reset")) {
        {
            robot_mutex.lock();
            defer robot_mutex.unlock();
            robot.slam_grid.reset();
        }
        var resp_buf: [256]u8 = undefined;
        const out = try protocol.formatResponse(&resp_buf, .{ .title = "slam_reset" });
        try sendWsText(conn, out);
        return;
    }
    if (std.mem.eql(u8, msg, "get_map")) {
        // Format the response into a heap buffer so we can stream the full
        // ASCII grid (GRID_SIZE * GRID_SIZE chars) plus JSON envelope.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const cap = grid_mod.GRID_SIZE * grid_mod.GRID_SIZE + 512;
        const buf = a.alloc(u8, cap) catch return;
        const written = blk: {
            robot_mutex.lock();
            defer robot_mutex.unlock();
            break :blk formatGetMapResponse(buf, &robot.slam_grid, robot.mapping) catch break :blk null;
        };
        if (written) |w| try sendWsText(conn, w);
        return;
    }
    if (std.mem.startsWith(u8, msg, "slam_plan ")) {
        const args = msg[10..];
        var iter = std.mem.tokenizeScalar(u8, args, ' ');
        const tx_str = iter.next() orelse return;
        const ty_str = iter.next() orelse return;
        const tx = std.fmt.parseInt(i32, tx_str, 10) catch return;
        const ty = std.fmt.parseInt(i32, ty_str, 10) catch return;
        var path_buf: [2048]path_planner.Point = undefined;
        const result = blk: {
            robot_mutex.lock();
            defer robot_mutex.unlock();
            const start = path_planner.Point{
                .x = robot.slam_grid.robotCellX(),
                .y = robot.slam_grid.robotCellY(),
            };
            const goal = path_planner.Point{
                .x = std.math.clamp(tx, 0, @as(i32, grid_mod.GRID_SIZE - 1)),
                .y = std.math.clamp(ty, 0, @as(i32, grid_mod.GRID_SIZE - 1)),
            };
            break :blk path_planner.findPath(&robot.slam_grid, start, goal, &path_buf);
        };
        var out_buf: [512]u8 = undefined;
        const out = try formatPlanResponse(&out_buf, result);
        try sendWsText(conn, out);
        return;
    }
}

fn startMappingThread(robot: *main_mod.RobotState) void {
    {
        robot_mutex.lock();
        defer robot_mutex.unlock();
        if (robot.mapping) return;
        robot.mapping = true;
    }
    slam_stop.store(false, .release);
    slam_thread = std.Thread.spawn(.{}, slamMappingLoop, .{robot}) catch null;
}

fn stopMappingThread(robot: *main_mod.RobotState) void {
    {
        robot_mutex.lock();
        defer robot_mutex.unlock();
        if (!robot.mapping) return;
        robot.mapping = false;
    }
    slam_stop.store(true, .release);
    if (slam_thread) |t| {
        t.join();
        slam_thread = null;
    }
}

fn slamMappingLoop(robot: *main_mod.RobotState) void {
    while (!slam_stop.load(.acquire)) {
        {
            robot_mutex.lock();
            defer robot_mutex.unlock();
            if (cfg.slam and cfg.ultrasonic) {
                const distance_cm = robot.ultrasonic.readDistance();
                const cells_f = distance_cm / grid_mod.CELL_CM;
                var cells: u32 = 0;
                if (cells_f > 0.0) cells = @intFromFloat(cells_f);
                const max_cells: u32 = grid_mod.GRID_SIZE - 1;
                const clamped = if (cells > max_cells) max_cells else cells;
                const obstacle_seen = distance_cm < 195.0;
                robot.slam_grid.scanUltrasonic(clamped, robot.slam_grid.pose_theta_rad, obstacle_seen);
            }
        }
        std.time.sleep(250_000_000);
    }
}

fn formatGetMapResponse(buf: []u8, grid: *const grid_mod.OccupancyGrid, mapping_active: bool) ![]u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    try w.writeAll("{\"status\":\"ok\",\"title\":\"get_map\",\"data\":{");
    try w.print("\"size\":{d},", .{grid_mod.GRID_SIZE});
    try w.print("\"cell_cm\":{d:.1},", .{grid_mod.CELL_CM});
    try w.print("\"x\":{d},", .{grid.robotCellX()});
    try w.print("\"y\":{d},", .{grid.robotCellY()});
    try w.print("\"theta\":{d:.4},", .{grid.pose_theta_rad});
    try w.print("\"frontiers\":{d},", .{grid.countFrontiers()});
    try w.print("\"coverage\":{d},", .{grid.coveragePercent()});
    try w.print("\"mapping\":{s},", .{if (mapping_active) "true" else "false"});
    try w.writeAll("\"grid\":\"");
    // Encode grid directly into the response buffer to avoid an extra copy.
    const encode_buf = buf[stream.pos .. stream.pos + grid_mod.GRID_SIZE * grid_mod.GRID_SIZE];
    const enc = grid.encodeAscii(encode_buf);
    stream.pos += enc.len;
    try w.writeAll("\"}}");
    return stream.getWritten();
}

fn formatPlanResponse(buf: []u8, path: ?[]path_planner.Point) ![]u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();
    try w.writeAll("{\"status\":\"ok\",\"title\":\"slam_plan\",\"data\":{");
    if (path) |p| {
        try w.print("\"found\":true,\"length\":{d}", .{p.len});
    } else {
        try w.writeAll("\"found\":false,\"length\":0");
    }
    try w.writeAll("}}");
    return stream.getWritten();
}

fn dispatchFunction(cmd: []const u8, robot: *main_mod.RobotState) void {
    if (std.mem.eql(u8, cmd, "findColor")) {
        robot.functions.find_color = true;
    } else if (std.mem.eql(u8, cmd, "motionGet")) {
        robot.functions.motion_detect = true;
    } else if (std.mem.eql(u8, cmd, "automatic")) {
        robot.functions.automatic = true;
    } else if (std.mem.eql(u8, cmd, "automaticOff")) {
        robot.functions.automatic = false;
        if (cfg.motor) robot.motor.stop();
    } else if (std.mem.eql(u8, cmd, "trackLine")) {
        robot.functions.track_line = true;
    } else if (std.mem.eql(u8, cmd, "trackLineOff")) {
        robot.functions.track_line = false;
        if (cfg.motor) robot.motor.stop();
    } else if (std.mem.eql(u8, cmd, "police")) {
        robot.functions.police = true;
        if (cfg.led) {
            robot.leds.police();
            for (0..6) |phase| {
                robot.leds.policeTick(@intCast(phase));
                std.time.sleep(80_000_000);
            }
        }
    } else if (std.mem.eql(u8, cmd, "policeOff")) {
        robot.functions.police = false;
        if (cfg.led) {
            robot.leds.setAll(.{ .r = 0, .g = 0, .b = 0 });
            robot.leds.show();
        }
    } else if (std.mem.eql(u8, cmd, "keepDistance")) {
        robot.functions.keep_distance = true;
    } else if (std.mem.eql(u8, cmd, "keepDistanceOff")) {
        robot.functions.keep_distance = false;
        if (cfg.motor) robot.motor.stop();
    } else if (std.mem.eql(u8, cmd, "CVFL")) {
        robot.functions.cv_line_follow = true;
    } else if (std.mem.eql(u8, cmd, "stopCV")) {
        robot.functions.find_color = false;
        robot.functions.motion_detect = false;
        robot.functions.cv_line_follow = false;
        if (cfg.servo) robot.servo.moveInit();
        if (cfg.motor) robot.motor.stop();
    }
}

fn dispatchAudio(cmd: []const u8, robot: *main_mod.RobotState) void {
    if (!cfg.buzzer) return;
    if (std.mem.startsWith(u8, cmd, "tone ")) {
        var iter = std.mem.tokenizeScalar(u8, cmd, ' ');
        _ = iter.next();
        const note = iter.next() orelse "C5";
        const duration_raw = iter.next() orelse "160";
        const duration_ms = std.fmt.parseInt(u32, duration_raw, 10) catch 160;
        robot.buzzer.playNote(note, @min(duration_ms, 800));
    } else if (std.mem.eql(u8, cmd, "tune seven_notes")) {
        const tune = [_]@import("../audio/buzzer.zig").NoteEntry{
            .{ .name = "C4", .duration_ms = 120 }, .{ .name = "D4", .duration_ms = 120 },
            .{ .name = "E4", .duration_ms = 120 }, .{ .name = "F4", .duration_ms = 120 },
            .{ .name = "G4", .duration_ms = 120 }, .{ .name = "A4", .duration_ms = 120 },
            .{ .name = "B4", .duration_ms = 160 },
        };
        robot.buzzer.playTune(&tune);
    } else if (std.mem.eql(u8, cmd, "tune baby_shark")) {
        const tune = [_]@import("../audio/buzzer.zig").NoteEntry{
            .{ .name = "G4", .duration_ms = 150 }, .{ .name = "A4", .duration_ms = 150 },
            .{ .name = "C5", .duration_ms = 150 }, .{ .name = "C5", .duration_ms = 150 },
            .{ .name = "C5", .duration_ms = 150 }, .{ .name = "C5", .duration_ms = 150 },
            .{ .name = "C5", .duration_ms = 220 }, .{ .name = "A4", .duration_ms = 150 },
            .{ .name = "G4", .duration_ms = 150 }, .{ .name = "A4", .duration_ms = 150 },
            .{ .name = "C5", .duration_ms = 280 },
        };
        robot.buzzer.playTune(&tune);
    } else if (std.mem.eql(u8, cmd, "tune happy_birthday")) {
        robot.buzzer.playTune(&@import("../audio/buzzer.zig").HAPPY_BIRTHDAY);
    }
}

fn dispatchLightEffect(cmd: []const u8, robot: *main_mod.RobotState) void {
    if (!cfg.led) return;
    if (std.mem.eql(u8, cmd, "lights_breath_blue")) {
        robot.leds.breath(70, 70, 255);
        for (0..12) |_| {
            robot.leds.breathTick();
            std.time.sleep(50_000_000);
        }
    } else if (std.mem.eql(u8, cmd, "lights_rainbow")) {
        robot.leds.rainbow();
        for (0..18) |_| {
            robot.leds.rainbowTick();
            std.time.sleep(40_000_000);
        }
    } else if (std.mem.eql(u8, cmd, "lights_flowing")) {
        robot.leds.flowing(255, 128, 0);
        for (0..16) |_| {
            robot.leds.flowingTick();
            std.time.sleep(45_000_000);
        }
    } else if (std.mem.eql(u8, cmd, "lights_off")) {
        robot.leds.off();
    }
}

fn dispatchSwitch(cmd: []const u8, robot: *main_mod.RobotState) void {
    if (cmd.len < 12) return;
    const port: usize = switch (cmd[7]) {
        '1' => 0,
        '2' => 1,
        '3' => 2,
        else => return,
    };
    const is_on = std.mem.endsWith(u8, cmd, "_on");
    robot.switches[port] = is_on;
    switch (port) {
        0 => robot.hal_ctx.gpio_led1.write(is_on),
        1 => robot.hal_ctx.gpio_led2.write(is_on),
        2 => robot.hal_ctx.gpio_led3.write(is_on),
        else => {},
    }
}

fn dispatchServo(cmd: []const u8, robot: *main_mod.RobotState) void {
    if (!cfg.servo) return;
    if (std.mem.eql(u8, cmd, "PWMINIT")) {
        robot.servo.moveInit();
        for (0..5) |i| robot.servo_pwm[i] = robot.servo.init_pos[i];
    } else if (std.mem.startsWith(u8, cmd, "PWMD")) {
        robot.servo.resetAll();
        for (0..5) |i| robot.servo_pwm[i] = 90;
    } else if (std.mem.startsWith(u8, cmd, "PWMMS")) {
        if (cmd.len > 6) {
            const n = std.fmt.parseInt(u8, cmd[6..], 10) catch return;
            robot.servo.moveAngle(n, 0);
        }
    } else if (std.mem.startsWith(u8, cmd, "SiLeft")) {
        if (cmd.len > 7) {
            const n = std.fmt.parseInt(u8, std.mem.trimLeft(u8, cmd[7..], " "), 10) catch return;
            if (n < 5 and robot.servo_pwm[n] > 2) {
                robot.servo_pwm[n] -= 2;
                robot.servo.setPWM(n, robot.servo_pwm[n]);
            }
        }
    } else if (std.mem.startsWith(u8, cmd, "SiRight")) {
        if (cmd.len > 8) {
            const n = std.fmt.parseInt(u8, std.mem.trimLeft(u8, cmd[8..], " "), 10) catch return;
            if (n < 5 and robot.servo_pwm[n] < 178) {
                robot.servo_pwm[n] += 2;
                robot.servo.setPWM(n, robot.servo_pwm[n]);
            }
        }
    }
}

fn generateInfoData(bufs: *[4][16]u8, robot: *main_mod.RobotState) [4][]const u8 {
    if (cfg.battery) robot.battery.read();
    const cpu_temp = 40.0 + simRand() * 25.0;
    const cpu_use = 5.0 + simRand() * 40.0;
    const ram_use = 30.0 + simRand() * 30.0;
    const battery: f64 = if (cfg.battery) @floatFromInt(robot.battery.percentage) else 60.0 + simRand() * 35.0;
    var s0 = std.io.fixedBufferStream(bufs[0][0..]);
    s0.writer().print("{d:.1}", .{cpu_temp}) catch {};
    var s1 = std.io.fixedBufferStream(bufs[1][0..]);
    s1.writer().print("{d:.1}", .{cpu_use}) catch {};
    var s2 = std.io.fixedBufferStream(bufs[2][0..]);
    s2.writer().print("{d:.1}", .{ram_use}) catch {};
    var s3 = std.io.fixedBufferStream(bufs[3][0..]);
    s3.writer().print("{d:.0}", .{battery}) catch {};
    return .{ bufs[0][0..s0.pos], bufs[1][0..s1.pos], bufs[2][0..s2.pos], bufs[3][0..s3.pos] };
}

fn computeAcceptKey(key: []const u8, out: *[28]u8) []const u8 {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(magic);
    const digest = hasher.finalResult();
    return std.base64.standard.Encoder.encode(out, &digest);
}

fn readWsFrame(conn: std.net.Stream, buf: []u8) ![]u8 {
    var header: [2]u8 = undefined;
    const h_read = try conn.read(&header);
    if (h_read < 2) return error.ConnectionClosed;
    if (header[0] & 0x0F == 0x8) return error.ConnectionClosed;
    const masked = (header[1] & 0x80) != 0;
    var payload_len: u64 = header[1] & 0x7F;
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        _ = try conn.read(&ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        _ = try conn.read(&ext);
        payload_len = std.mem.readInt(u64, &ext, .big);
    }
    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) _ = try conn.read(&mask_key);
    if (payload_len > buf.len) return error.PayloadTooLarge;
    const len: usize = @intCast(payload_len);
    var total_read: usize = 0;
    while (total_read < len) {
        const n = try conn.read(buf[total_read..len]);
        if (n == 0) return error.ConnectionClosed;
        total_read += n;
    }
    if (masked) for (0..len) |i| {
        buf[i] ^= mask_key[i % 4];
    };
    return buf[0..len];
}

fn sendWsText(conn: std.net.Stream, data: []const u8) !void {
    var hdr: [10]u8 = undefined;
    hdr[0] = 0x81;
    var hdr_len: usize = 0;
    if (data.len < 126) {
        hdr[1] = @intCast(data.len);
        hdr_len = 2;
    } else if (data.len < 65536) {
        hdr[1] = 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(data.len), .big);
        hdr_len = 4;
    } else {
        hdr[1] = 127;
        std.mem.writeInt(u64, hdr[2..10], data.len, .big);
        hdr_len = 10;
    }
    try conn.writeAll(hdr[0..hdr_len]);
    try conn.writeAll(data);
}

pub fn run(allocator: std.mem.Allocator, robot: *main_mod.RobotState, port: u16) !void {
    _ = allocator;
    loadCredentials();
    if (auth_user.len == 0 or auth_pass.len == 0) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("[AWR-V3 Zig] WARNING: AWR_WS_USER/AWR_WS_PASS not set, auth will reject all\n", .{});
    }
    const address = std.net.Address.parseIp4("0.0.0.0", port) catch unreachable;
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    const stdout = std.io.getStdOut().writer();
    try stdout.print("[AWR-V3 Zig] WebSocket server listening on ws://0.0.0.0:{d}\n", .{port});
    while (true) {
        const conn = try server.accept();
        const thread = try std.Thread.spawn(.{}, handleConnectionThread, .{ conn.stream, robot });
        thread.detach();
    }
}

fn handleConnectionThread(conn: std.net.Stream, robot: *main_mod.RobotState) void {
    defer conn.close();
    handleConnection(conn, robot);
}

test "protocol integration" {
    var buf: [512]u8 = undefined;
    const resp = protocol.Response{};
    const out = try protocol.formatResponse(&buf, resp);
    try std.testing.expect(out.len > 0);
}

test "SLAM get_map response carries grid envelope" {
    if (!cfg.slam) return;
    var grid = grid_mod.OccupancyGrid.init();
    grid.updateCell(40, 40, false);
    grid.updateCell(40, 40, false);
    var buf: [grid_mod.GRID_SIZE * grid_mod.GRID_SIZE + 512]u8 = undefined;
    const out = try formatGetMapResponse(&buf, &grid, true);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\":\"get_map\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"size\":80") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"mapping\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"grid\":\"") != null);
}

test "SLAM slam_plan response with no path" {
    var buf: [256]u8 = undefined;
    const out = try formatPlanResponse(&buf, null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"found\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"length\":0") != null);
}
