const std = @import("std");
const grid_mod = @import("occupancy_grid.zig");

const Point = struct { x: i32, y: i32 };

const Node = struct {
    pos: Point,
    g_cost: f32,
    h_cost: f32,
    parent_idx: ?usize,

    fn fCost(self: *const Node) f32 {
        return self.g_cost + self.h_cost;
    }
};

fn heuristic(a: Point, b: Point) f32 {
    const dx: f32 = @floatFromInt(a.x - b.x);
    const dy: f32 = @floatFromInt(a.y - b.y);
    return @abs(dx) + @abs(dy); // Manhattan distance
}

/// Find path from start to goal using A* on occupancy grid
/// Returns path as array of points (caller must provide buffer)
pub fn findPath(
    grid: *const grid_mod.OccupancyGrid,
    start: Point,
    goal: Point,
    path_buf: []Point,
) ?[]Point {
    if (start.x == goal.x and start.y == goal.y) {
        path_buf[0] = start;
        return path_buf[0..1];
    }

    // Simple BFS-like A* with fixed-size arrays for sandbox compatibility
    var open_list: [2048]Node = undefined;
    var open_count: usize = 0;
    var closed: [grid_mod.GRID_SIZE][grid_mod.GRID_SIZE]bool = undefined;
    for (0..grid_mod.GRID_SIZE) |y| {
        for (0..grid_mod.GRID_SIZE) |x| {
            closed[y][x] = false;
        }
    }
    var parents: [grid_mod.GRID_SIZE][grid_mod.GRID_SIZE]Point = undefined;
    for (0..grid_mod.GRID_SIZE) |y| {
        for (0..grid_mod.GRID_SIZE) |x| {
            parents[y][x] = .{ .x = -1, .y = -1 };
        }
    }

    // Add start node
    open_list[0] = .{
        .pos = start,
        .g_cost = 0,
        .h_cost = heuristic(start, goal),
        .parent_idx = null,
    };
    open_count = 1;

    const dirs = [_]Point{
        .{ .x = 0, .y = -1 }, .{ .x = 0, .y = 1 },
        .{ .x = -1, .y = 0 }, .{ .x = 1, .y = 0 },
    };

    var iterations: u32 = 0;
    while (open_count > 0 and iterations < 5000) {
        iterations += 1;

        // Find node with lowest f_cost
        var best_idx: usize = 0;
        var best_f: f32 = open_list[0].fCost();
        for (1..open_count) |i| {
            const f = open_list[i].fCost();
            if (f < best_f) {
                best_f = f;
                best_idx = i;
            }
        }

        const current = open_list[best_idx];
        // Remove from open list (swap with last)
        open_list[best_idx] = open_list[open_count - 1];
        open_count -= 1;

        const cx: usize = @intCast(current.pos.x);
        const cy: usize = @intCast(current.pos.y);
        if (closed[cy][cx]) continue;
        closed[cy][cx] = true;

        // Check if we reached the goal
        if (current.pos.x == goal.x and current.pos.y == goal.y) {
            // Reconstruct path
            var path_len: usize = 0;
            var trace = goal;
            while (trace.x != start.x or trace.y != start.y) {
                if (path_len >= path_buf.len) return null;
                path_buf[path_len] = trace;
                path_len += 1;
                trace = parents[@intCast(trace.y)][@intCast(trace.x)];
                if (trace.x == -1) return null;
            }
            path_buf[path_len] = start;
            path_len += 1;
            // Reverse
            var lo: usize = 0;
            var hi: usize = path_len - 1;
            while (lo < hi) {
                const tmp = path_buf[lo];
                path_buf[lo] = path_buf[hi];
                path_buf[hi] = tmp;
                lo += 1;
                hi -= 1;
            }
            return path_buf[0..path_len];
        }

        // Expand neighbors
        for (dirs) |d| {
            const nx = current.pos.x + d.x;
            const ny = current.pos.y + d.y;
            if (nx < 0 or ny < 0 or nx >= grid_mod.GRID_SIZE or ny >= grid_mod.GRID_SIZE) continue;
            const ux: usize = @intCast(nx);
            const uy: usize = @intCast(ny);
            if (closed[uy][ux]) continue;
            if (grid.getState(ux, uy) == .occupied) continue;

            const new_g = current.g_cost + 1.0;
            if (open_count < open_list.len) {
                parents[uy][ux] = current.pos;
                open_list[open_count] = .{
                    .pos = .{ .x = nx, .y = ny },
                    .g_cost = new_g,
                    .h_cost = heuristic(.{ .x = nx, .y = ny }, goal),
                    .parent_idx = null,
                };
                open_count += 1;
            }
        }
    }

    return null; // No path found
}

test "A* finds simple path" {
    var grid = grid_mod.OccupancyGrid.init();
    // Clear area
    for (0..20) |y| {
        for (0..20) |x| {
            grid.updateCell(x, y, false);
            grid.updateCell(x, y, false);
        }
    }

    var path_buf: [256]Point = undefined;
    const start = Point{ .x = 0, .y = 0 };
    const goal = Point{ .x = 5, .y = 5 };
    const result = findPath(&grid, start, goal, &path_buf);
    try std.testing.expect(result != null);
    const path = result.?;
    try std.testing.expect(path.len > 0);
    try std.testing.expectEqual(start.x, path[0].x);
    try std.testing.expectEqual(goal.x, path[path.len - 1].x);
}

test "A* handles obstacles" {
    var grid = grid_mod.OccupancyGrid.init();
    // Create free area
    for (0..20) |y| {
        for (0..20) |x| {
            grid.updateCell(x, y, false);
            grid.updateCell(x, y, false);
        }
    }
    // Add wall
    for (0..10) |y| {
        grid.updateCell(5, y, true);
        grid.updateCell(5, y, true);
        grid.updateCell(5, y, true);
    }

    var path_buf: [256]Point = undefined;
    const result = findPath(&grid, .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 }, &path_buf);
    try std.testing.expect(result != null);
    // Path should go around the wall
    const path = result.?;
    try std.testing.expect(path.len > 10); // Must be longer than straight line
}
