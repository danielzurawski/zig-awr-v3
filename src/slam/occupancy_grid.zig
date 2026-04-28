const std = @import("std");

pub const GRID_SIZE: usize = 80;
const LOG_ODDS_FREE: f32 = -0.4;
const LOG_ODDS_OCC: f32 = 0.85;
const LOG_ODDS_PRIOR: f32 = 0.0;
const LOG_ODDS_MAX: f32 = 5.0;
const LOG_ODDS_MIN: f32 = -5.0;

pub const CellState = enum(u2) { unknown = 0, free = 1, occupied = 2 };

/// Real-world width (in cm) covered by one occupancy cell. With GRID_SIZE=80
/// and 10 cm per cell, the grid covers an 8 m × 8 m area. Adjust if you change
/// the robot footprint or the room size.
pub const CELL_CM: f32 = 10.0;

pub const OccupancyGrid = struct {
    cells: [GRID_SIZE][GRID_SIZE]f32 = undefined,
    /// Sub-cell pose in continuous (cell) coordinates so dead-reckoning does
    /// not lose information across many small movements.
    pose_x: f32 = @as(f32, GRID_SIZE / 2),
    pose_y: f32 = @as(f32, GRID_SIZE / 2),
    /// Heading in radians: 0 points along +x ("east"), pi/2 along +y ("north").
    pose_theta_rad: f32 = 0.0,
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
        self.pose_x = @as(f32, GRID_SIZE / 2);
        self.pose_y = @as(f32, GRID_SIZE / 2);
        self.pose_theta_rad = 0.0;
        self.cells_explored = 0;
    }

    pub fn robotCellX(self: *const OccupancyGrid) i32 {
        return @intFromFloat(std.math.clamp(self.pose_x, 0.0, @as(f32, GRID_SIZE - 1)));
    }

    pub fn robotCellY(self: *const OccupancyGrid) i32 {
        return @intFromFloat(std.math.clamp(self.pose_y, 0.0, @as(f32, GRID_SIZE - 1)));
    }

    /// Apply a rotation update (positive = counterclockwise/left).
    pub fn applyRotate(self: *OccupancyGrid, delta_rad: f32) void {
        var t = self.pose_theta_rad + delta_rad;
        const tau = std.math.pi * 2.0;
        while (t > std.math.pi) t -= tau;
        while (t < -std.math.pi) t += tau;
        self.pose_theta_rad = t;
    }

    /// Advance the robot pose by `step_cm` along its current heading.
    /// `direction` should be +1 for forward, -1 for backward.
    pub fn applyTranslate(self: *OccupancyGrid, step_cm: f32, direction: i8) void {
        const cells = step_cm / CELL_CM;
        const dirf: f32 = @floatFromInt(direction);
        const dx = @cos(self.pose_theta_rad) * cells * dirf;
        const dy = @sin(self.pose_theta_rad) * cells * dirf;
        self.pose_x = std.math.clamp(self.pose_x + dx, 0.0, @as(f32, GRID_SIZE - 1));
        self.pose_y = std.math.clamp(self.pose_y + dy, 0.0, @as(f32, GRID_SIZE - 1));
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

    /// Cast an ultrasonic ray from the robot pose along `heading_rad` and
    /// integrate `distance_cells` cells of free space, marking the endpoint
    /// as occupied if `endpoint_is_obstacle` is true (i.e. the sensor saw a
    /// real reflection rather than timing out at max range).
    pub fn scanUltrasonic(
        self: *OccupancyGrid,
        distance_cells: u32,
        heading_rad: f32,
        endpoint_is_obstacle: bool,
    ) void {
        const cos_h = @cos(heading_rad);
        const sin_h = @sin(heading_rad);

        var i: u32 = 0;
        while (i < distance_cells) : (i += 1) {
            const fi: f32 = @floatFromInt(i);
            const fx: f32 = self.pose_x + fi * cos_h;
            const fy: f32 = self.pose_y + fi * sin_h;
            const cx: i32 = @intFromFloat(fx);
            const cy: i32 = @intFromFloat(fy);
            if (cx < 0 or cy < 0 or cx >= GRID_SIZE or cy >= GRID_SIZE) break;
            self.updateCell(@intCast(cx), @intCast(cy), false);
        }
        if (endpoint_is_obstacle) {
            const fd: f32 = @floatFromInt(distance_cells);
            const ex: f32 = self.pose_x + fd * cos_h;
            const ey: f32 = self.pose_y + fd * sin_h;
            const ecx: i32 = @intFromFloat(ex);
            const ecy: i32 = @intFromFloat(ey);
            if (ecx >= 0 and ecy >= 0 and ecx < GRID_SIZE and ecy < GRID_SIZE) {
                self.updateCell(@intCast(ecx), @intCast(ecy), true);
            }
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

    pub fn coveragePercent(self: *const OccupancyGrid) u8 {
        const total: f32 = @floatFromInt(GRID_SIZE * GRID_SIZE);
        const explored: f32 = @floatFromInt(self.cells_explored);
        return @intFromFloat(std.math.clamp(explored / total * 100.0, 0.0, 100.0));
    }

    /// Encode the grid as a compact ASCII string (one char per cell, row-major)
    /// suitable for streaming over the WebSocket protocol.
    /// `?` = unknown, `.` = free, `#` = occupied.
    pub fn encodeAscii(self: *const OccupancyGrid, out: []u8) []u8 {
        const need = GRID_SIZE * GRID_SIZE;
        const limit = if (out.len < need) out.len else need;
        var idx: usize = 0;
        for (0..GRID_SIZE) |y| {
            for (0..GRID_SIZE) |x| {
                if (idx >= limit) break;
                const c = switch (self.getState(x, y)) {
                    .unknown => @as(u8, '?'),
                    .free => @as(u8, '.'),
                    .occupied => @as(u8, '#'),
                };
                out[idx] = c;
                idx += 1;
            }
        }
        return out[0..idx];
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

test "OccupancyGrid scan along heading" {
    var grid = OccupancyGrid.init();
    grid.pose_x = 40.0;
    grid.pose_y = 40.0;
    grid.pose_theta_rad = 0.0;
    grid.scanUltrasonic(10, 0.0, true);
    grid.scanUltrasonic(10, 0.0, true);
    try std.testing.expectEqual(CellState.free, grid.getState(45, 40));
    try std.testing.expectEqual(CellState.occupied, grid.getState(50, 40));
}

test "OccupancyGrid pose updates" {
    var grid = OccupancyGrid.init();
    const start_x = grid.pose_x;
    grid.applyTranslate(20.0, 1);
    try std.testing.expect(grid.pose_x > start_x);
    grid.applyRotate(std.math.pi / 2.0);
    try std.testing.expect(grid.pose_theta_rad > 1.0);
}

test "OccupancyGrid encodeAscii" {
    var grid = OccupancyGrid.init();
    grid.updateCell(0, 0, false);
    grid.updateCell(0, 0, false);
    grid.updateCell(1, 0, true);
    grid.updateCell(1, 0, true);
    var buf: [GRID_SIZE * GRID_SIZE]u8 = undefined;
    const enc = grid.encodeAscii(&buf);
    try std.testing.expectEqual(@as(u8, '.'), enc[0]);
    try std.testing.expectEqual(@as(u8, '#'), enc[1]);
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
