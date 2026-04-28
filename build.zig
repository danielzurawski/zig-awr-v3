const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Feature toggles ──────────────────────────────────────────────
    const features = .{
        .motor = b.option(bool, "motor", "Enable motor subsystem") orelse true,
        .servo = b.option(bool, "servo", "Enable servo subsystem") orelse true,
        .ultrasonic = b.option(bool, "ultrasonic", "Enable ultrasonic sensor") orelse true,
        .line_tracker = b.option(bool, "line_tracker", "Enable IR line tracker") orelse true,
        .battery = b.option(bool, "battery", "Enable battery monitor") orelse true,
        .led = b.option(bool, "led", "Enable WS2812 LEDs") orelse true,
        .buzzer = b.option(bool, "buzzer", "Enable buzzer") orelse true,
        .camera = b.option(bool, "camera", "Enable camera/vision") orelse true,
        .slam = b.option(bool, "slam", "Enable SLAM/occupancy grid") orelse true,
        .autonomy = b.option(bool, "autonomy", "Enable autonomy behaviors") orelse true,
        .sim = b.option(bool, "sim", "Use simulation HAL backend") orelse true,
    };

    const options = b.addOptions();
    options.addOption(bool, "motor", features.motor);
    options.addOption(bool, "servo", features.servo);
    options.addOption(bool, "ultrasonic", features.ultrasonic);
    options.addOption(bool, "line_tracker", features.line_tracker);
    options.addOption(bool, "battery", features.battery);
    options.addOption(bool, "led", features.led);
    options.addOption(bool, "buzzer", features.buzzer);
    options.addOption(bool, "camera", features.camera);
    options.addOption(bool, "slam", features.slam);
    options.addOption(bool, "autonomy", features.autonomy);
    options.addOption(bool, "sim", features.sim);

    // ── Main executable ──────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "awr-v3",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("config", options);
    b.installArtifact(exe);

    // ── Hardware diagnostics executable ──────────────────────────────
    const diag = b.addExecutable(.{
        .name = "awr-v3-diag",
        .root_source_file = b.path("src/diag.zig"),
        .target = target,
        .optimize = optimize,
    });
    diag.root_module.addOptions("config", options);
    b.installArtifact(diag);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the AWR-V3 firmware");
    run_step.dependOn(&run_cmd.step);

    const run_diag_cmd = b.addRunArtifact(diag);
    run_diag_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_diag_cmd.addArgs(args);
    const diag_step = b.step("diag", "Run AWR-V3 hardware diagnostics");
    diag_step.dependOn(&run_diag_cmd.step);

    // ── Unit tests ───────────────────────────────────────────────────
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addOptions("config", options);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
