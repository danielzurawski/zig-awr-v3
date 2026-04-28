const std = @import("std");

pub const GRID_SIZE: usize = 80;
const LOG_ODDS_FREE: f32 = -0.4;
const LOG_ODDS_OCC: f32 = 0.85;
const LOG_ODDS_PRIOR: f32 = 0.0;
const LOG_ODDS_MAX: f32 = 5.0;
const LOG_ODDS_MIN: f32 = -5.0;

pub const CellState = enum(u2) { unknown = 0, free = 1, occupied = 2 };

pub const OccupancyGrid = struct {
    cells: [GRID_SIZE][GRID_SIZE]f32 = undefined,
    robot_x: i32 = @as(i32, GRID_SIZE / 2),
    robot_y: i32 = @as(i32, GRID_SIZE / 2),
    cells_explored: u32 = 0,

    pub fn init() OccupancyGrid {
        var grid = OccupancyGrid{};
        grid.reset();
        return grid;
    }

    pub fn reset(self: *OccupancyGrid) void {
        for (0..GRID_SIZE) |y| {
            for (0..GRID_SIZE) |x| {
                self.cells[y][x] = LOG_ODDS_PRIOR;
            }
        }
        self.robot_x = @as(i32, GRID_SIZE / 2);
        self.robot_y = @as(i32, GRID_SIZE / 2);
        self.cells_explored = 0;
    }

    pub fn getState(self: *const OccupancyGrid, x: usize, y: usize) CellState {
        if (x >= GRID_SIZE or y >= GRID_SIZE) return .unknown;
        const val = self.cells[y][x];
        if (val > 0.5) return .occupied;
        if (val < -0.5) return .free;
        return .unknown;
    }

    pub fn probability(self: *const OccupancyGrid, x: usize, y: usize) f32 {
        if (x >= GRID_SIZE or y >= GRID_SIZE) return 0.5;
        const l = self.cells[y][x];
        return 1.0 - 1.0 / (1.0 + @exp(l));
    }

    /// Update a cell with a sensor observation using Bayesian log-odds
    pub fn updateCell(self: *OccupancyGrid, x: usize, y: usize, is_occupied: bool) void {
        if (x >= GRID_SIZE or y >= GRID_SIZE) return;
        const was_unknown = self.cells[y][x] == LOG_ODDS_PRIOR;
        const update = if (is_occupied) LOG_ODDS_OCC else LOG_ODDS_FREE;
        self.cells[y][x] = std.math.clamp(self.cells[y][x] + update, LOG_ODDS_MIN, LOG_ODDS_MAX);
        if (was_unknown and self.cells[y][x] != LOG_ODDS_PRIOR) {
            self.cells_explored += 1;
        }
    }

    /// Simulate an ultrasonic scan from robot position with given heading
    pub fn scanUltrasonic(self: *OccupancyGrid, distance_cells: u32, heading_rad: f32) void {
        const cos_h = @cos(heading_rad);
        const sin_h = @sin(heading_rad);

        var i: u32 = 0;
        while (i < distance_cells) : (i += 1) {
            const fx: f32 = @as(f32, @floatFromInt(self.robot_x)) + @as(f32, @floatFromInt(i)) * cos_h;
            const fy: f32 = @as(f32, @floatFromInt(self.robot_y)) + @as(f32, @floatFromInt(i)) * sin_h;
            const cx: i32 = @intFromFloat(fx);
            const cy: i32 = @intFromFloat(fy);
            if (cx < 0 or cy < 0 or cx >= GRID_SIZE or cy >= GRID_SIZE) break;
            self.updateCell(@intCast(cx), @intCast(cy), false); // Free space along ray
        }
        // Mark the endpoint as occupied
        const ex: f32 = @as(f32, @floatFromInt(self.robot_x)) + @as(f32, @floatFromInt(distance_cells)) * cos_h;
        const ey: f32 = @as(f32, @floatFromInt(self.robot_y)) + @as(f32, @floatFromInt(distance_cells)) * sin_h;
        const ecx: i32 = @intFromFloat(ex);
        const ecy: i32 = @intFromFloat(ey);
        if (ecx >= 0 and ecy >= 0 and ecx < GRID_SIZE and ecy < GRID_SIZE) {
            self.updateCell(@intCast(ecx), @intCast(ecy), true);
        }
    }

    /// Count frontier cells (unknown cells adjacent to free cells)
    pub fn countFrontiers(self: *const OccupancyGrid) u32 {
        var count: u32 = 0;
        for (1..GRID_SIZE - 1) |y| {
            for (1..GRID_SIZE - 1) |x| {
                if (self.getState(x, y) == .unknown) {
                    // Check if adjacent to a free cell
                    if (self.getState(x - 1, y) == .free or
                        self.getState(x + 1, y) == .free or
                        self.getState(x, y - 1) == .free or
                        self.getState(x, y + 1) == .free)
                    {
                        count += 1;
                    }
                }
            }
        }
        return count;
    }

    pub fn moveRobot(self: *OccupancyGrid, dx: i32, dy: i32) void {
        self.robot_x = std.math.clamp(self.robot_x + dx, 0, @as(i32, GRID_SIZE - 1));
        self.robot_y = std.math.clamp(self.robot_y + dy, 0, @as(i32, GRID_SIZE - 1));
    }

    pub fn coveragePercent(self: *const OccupancyGrid) u8 {
        const total: f32 = @floatFromInt(GRID_SIZE * GRID_SIZE);
        const explored: f32 = @floatFromInt(self.cells_explored);
        return @intFromFloat(std.math.clamp(explored / total * 100.0, 0.0, 100.0));
    }
};

test "OccupancyGrid init and update" {
    var grid = OccupancyGrid.init();
    try std.testing.expectEqual(CellState.unknown, grid.getState(40, 40));

    grid.updateCell(40, 40, true);
    grid.updateCell(40, 40, true);
    try std.testing.expectEqual(CellState.occupied, grid.getState(40, 40));

    grid.updateCell(10, 10, false);
    grid.updateCell(10, 10, false);
    try std.testing.expectEqual(CellState.free, grid.getState(10, 10));
}

test "OccupancyGrid scan" {
    var grid = OccupancyGrid.init();
    grid.robot_x = 40;
    grid.robot_y = 40;
    grid.scanUltrasonic(10, 0.0);
    grid.scanUltrasonic(10, 0.0);
    try std.testing.expectEqual(CellState.free, grid.getState(45, 40));
    try std.testing.expectEqual(CellState.occupied, grid.getState(50, 40));
}

test "OccupancyGrid coverage" {
    var grid = OccupancyGrid.init();
    try std.testing.expectEqual(@as(u8, 0), grid.coveragePercent());
    // Update some cells
    for (0..100) |i| {
        grid.updateCell(i % GRID_SIZE, i / GRID_SIZE, false);
    }
    try std.testing.expect(grid.coveragePercent() > 0);
}
