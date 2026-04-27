const std = @import("std");
const cfg = @import("config");

const hal = @import("hal.zig");
const ws_server = @import("net/ws_server.zig");
const motor_mod = @import("motor/driver.zig");
const servo_mod = @import("servo/controller.zig");
const sensor_ultra = @import("sensor/ultrasonic.zig");
const sensor_battery = @import("sensor/battery.zig");
const sensor_line = @import("sensor/line_tracker.zig");
const led_mod = @import("led/ws2812.zig");
const buzzer_mod = @import("audio/buzzer.zig");
const slam_mod = @import("slam/occupancy_grid.zig");

// ── Robot state (shared across subsystems) ───────────────────────────
pub const RobotState = struct {
    speed: u8 = 50,
    moving: bool = false,
    move_cmd: []const u8 = "",
    tilt_cmd: []const u8 = "",
    functions: FunctionState = .{},
    switches: [3]bool = .{ false, false, false },
    servo_pwm: [5]u8 = .{ 90, 90, 90, 90, 90 },
    hal_ctx: *hal.HalContext,
    motor: if (cfg.motor) motor_mod.MotorDriver else void,
    servo: if (cfg.servo) servo_mod.ServoController else void,
    ultrasonic: if (cfg.ultrasonic) sensor_ultra.Ultrasonic else void,
    battery: if (cfg.battery) sensor_battery.BatteryMonitor else void,
    line_tracker: if (cfg.line_tracker) sensor_line.LineTracker else void,
    leds: if (cfg.led) led_mod.Ws2812 else void,
    buzzer: if (cfg.buzzer) buzzer_mod.Buzzer else void,
    slam_grid: if (cfg.slam) slam_mod.OccupancyGrid else void,

    pub fn init(hal_ctx: *hal.HalContext) RobotState {
        return .{
            .hal_ctx = hal_ctx,
            .motor = if (cfg.motor) motor_mod.MotorDriver.init(hal_ctx) else {},
            .servo = if (cfg.servo) servo_mod.ServoController.init(hal_ctx) else {},
            .ultrasonic = if (cfg.ultrasonic) sensor_ultra.Ultrasonic.init(hal_ctx) else {},
            .battery = if (cfg.battery) sensor_battery.BatteryMonitor.init(hal_ctx) else {},
            .line_tracker = if (cfg.line_tracker) sensor_line.LineTracker.init(hal_ctx) else {},
            .leds = if (cfg.led) led_mod.Ws2812.init(hal_ctx) else {},
            .buzzer = if (cfg.buzzer) buzzer_mod.Buzzer.init(hal_ctx) else {},
            .slam_grid = if (cfg.slam) slam_mod.OccupancyGrid.init() else {},
        };
    }
};

pub const FunctionState = struct {
    find_color: bool = false,
    motion_detect: bool = false,
    automatic: bool = false,
    track_line: bool = false,
    keep_distance: bool = false,
    police: bool = false,
    cv_line_follow: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("[AWR-V3 Zig] Starting with features: ", .{});
    try stdout.print("motor={} servo={} ultra={} line={} bat={} led={} buzz={} cam={} slam={} auto={} sim={}\n", .{
        cfg.motor, cfg.servo, cfg.ultrasonic, cfg.line_tracker,
        cfg.battery,    cfg.led,    cfg.buzzer,     cfg.camera,
        cfg.slam,       cfg.autonomy, cfg.sim,
    });

    // Initialize HAL
    var hal_ctx = hal.HalContext.init();
    defer hal_ctx.deinit();

    // Initialize robot state
    var robot = RobotState.init(&hal_ctx);

    // Initialize SLAM if enabled
    if (cfg.slam) {
        robot.slam_grid.reset();
        try stdout.print("[AWR-V3 Zig] SLAM occupancy grid initialized ({d}x{d})\n", .{ slam_mod.GRID_SIZE, slam_mod.GRID_SIZE });
    }

    // Start WebSocket server
    try stdout.print("[AWR-V3 Zig] Starting WebSocket server on port 8889\n", .{});
    try ws_server.run(allocator, &robot, 8889);
}

// ── Unit tests ───────────────────────────────────────────────────────
test {
    _ = @import("control/pid.zig");
    _ = @import("control/kalman.zig");
    _ = @import("slam/occupancy_grid.zig");
    _ = @import("slam/path_planner.zig");
    _ = @import("motor/driver.zig");
    _ = @import("servo/controller.zig");
    _ = @import("sensor/ultrasonic.zig");
    _ = @import("sensor/battery.zig");
    _ = @import("sensor/line_tracker.zig");
    _ = @import("led/ws2812.zig");
    _ = @import("audio/buzzer.zig");
    _ = @import("hal.zig");
    _ = @import("net/ws_server.zig");
    _ = @import("net/protocol.zig");
}