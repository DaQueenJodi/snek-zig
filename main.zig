const std = @import("std");
const c = @import("c.zig");


const DEFAULT_WINDOW_WIDTH  = 800;
const DEFAULT_WINDOW_HEIGHT = 600;
const CELL_SIZE     = 10;
const GRID_WIDTH    = 30;
const GRID_HEIGHT   = 30;

const FONT_SIZE  = 14;
const TEXT_COLOR = c.PURPLE;

const BACKGROUND_COLOR       = c.WHITE;
const FRAME_COLOR            = c.BLACK;
const EMPTY_TILE_COLOR       = c.BEIGE;
const APPLE_TILE_COLOR       = c.RED;
const SNAKE_HEAD_TILE_COLOR  = c.DARKGREEN;
const SNAKE_TAIL_TILE_COLORS = [_]c.Color{c.GREEN, c.LIME};

const LEFT_KEYS  = [_]c_int{c.KEY_LEFT,  c.KEY_A, c.KEY_H};
const RIGHT_KEYS = [_]c_int{c.KEY_RIGHT, c.KEY_D, c.KEY_L};
const UP_KEYS    = [_]c_int{c.KEY_UP,    c.KEY_W, c.KEY_K};
const DOWN_KEYS  = [_]c_int{c.KEY_DOWN,  c.KEY_S, c.KEY_J};

const NS_PER_FRAME = std.time.ns_per_s / 16;

inline fn drawTile(grid_start_x: usize, grid_start_y: usize, pos: Pos, color: c.Color) void {
    c.DrawRectangle(@intCast(grid_start_x + pos.x*CELL_SIZE), @intCast(grid_start_y + pos.y*CELL_SIZE), CELL_SIZE, CELL_SIZE, color);
}


const Direction = enum {
    left,
    right,
    up,
    down
};

fn moveDir(dir: Direction, pos: Pos) Pos {
    var ret = pos;
    const Offset = union(enum) { x: i32, y: i32 };
    const offset: Offset = switch (dir) {
        .left  => .{.x = -1},
        .right => .{.x =  1},
        .up    => .{.y = -1},
        .down  => .{.y =  1}
    };
    const x: i32 = @intCast(ret.x);
    const y: i32 = @intCast(ret.y);
    switch (offset) {
        .x => |dx| ret.x = @intCast(@mod(x + dx, GRID_WIDTH)),
        .y => |dy| ret.y = @intCast(@mod(y + dy, GRID_HEIGHT))
    }
    return ret;
}

fn getKeyDirs(dirs: *std.ArrayList(Direction)) !void {
    for (LEFT_KEYS)  |k| if (c.IsKeyPressed(k)) try dirs.append(.left);
    for (RIGHT_KEYS) |k| if (c.IsKeyPressed(k)) try dirs.append(.right);
    for (DOWN_KEYS)  |k| if (c.IsKeyPressed(k)) try dirs.append(.down);
    for (UP_KEYS)    |k| if (c.IsKeyPressed(k)) try dirs.append(.up);
}

const Pos = struct {x: usize, y: usize};
fn genAppleLoc(rand: std.rand.Random) Pos {
    return Pos{
        .x = rand.intRangeLessThan(usize, 0, GRID_WIDTH),
        .y = rand.intRangeLessThan(usize, 0, GRID_HEIGHT)
    };
}

pub fn main() !void {

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var seed: u64 = undefined;
    try std.os.getrandom(std.mem.asBytes(&seed));
    var pcg = std.rand.Pcg.init(seed);
    const rand = pcg.random();

    c.SetTraceLogLevel(c.LOG_WARNING | c.LOG_ERROR | c.LOG_FATAL);
    c.SetTargetFPS(60);
    c.SetConfigFlags(c.FLAG_WINDOW_RESIZABLE);
    c.InitWindow(DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT, "snake");

    var window_width: usize = @intCast(c.GetScreenWidth());
    var window_height: usize = @intCast(c.GetScreenHeight());

    var apple: Pos = undefined;

    // snake variables
    var is_dead = false;
    var parts = std.ArrayList(Pos).init(allocator);
    defer parts.deinit();
    try parts.append(.{.x = GRID_WIDTH/2, .y = GRID_HEIGHT/2});
    // chosen by player when starting
    var head_dir: Direction = undefined;

    var dir_queue = std.ArrayList(Direction).init(allocator);
    defer dir_queue.deinit();

    // update loop variables
    var started = false;
    var time_until_update: u64 = 0;

    // drawing variables
    while (!c.WindowShouldClose()) {
        {
            c.BeginDrawing();
            defer c.EndDrawing();

            c.ClearBackground(BACKGROUND_COLOR);


            const center_x     = @divFloor(window_width, 2);
            const center_y     = @divFloor(window_height, 2);
            const grid_height  = GRID_HEIGHT*CELL_SIZE;
            const grid_width   = GRID_WIDTH*CELL_SIZE;
            const grid_start_x = center_x - @divFloor(grid_width, 2);
            const grid_start_y = center_y - @divFloor(grid_height, 2);


            // render text
            const length_text = try std.fmt.allocPrintZ(allocator, "length: {}!", .{parts.items.len});
            defer allocator.free(length_text);
            c.DrawText(length_text.ptr, @intCast(grid_start_x), @intCast(grid_start_y - FONT_SIZE), FONT_SIZE, TEXT_COLOR);
            if (is_dead) {
                c.DrawText("You died :(", @intCast(grid_start_x), @intCast(grid_start_y - FONT_SIZE*3), FONT_SIZE, TEXT_COLOR);
                c.DrawText("press R to restart or Q to quit", @intCast(grid_start_x), @intCast(grid_start_y - FONT_SIZE*2), FONT_SIZE, TEXT_COLOR);
            }

            // render frame
            c.DrawRectangleLines(@intCast(grid_start_x-1), @intCast(grid_start_y-1), grid_width+2, grid_height+2, FRAME_COLOR);

            // render grid
            c.DrawRectangle(@intCast(grid_start_x), @intCast(grid_start_y), GRID_WIDTH*CELL_SIZE, GRID_HEIGHT*CELL_SIZE, EMPTY_TILE_COLOR);
            if (started) drawTile(grid_start_x, grid_start_y, apple, APPLE_TILE_COLOR);
            drawTile(grid_start_x, grid_start_y, parts.items[0], SNAKE_HEAD_TILE_COLOR);
            for (parts.items[1..], 0..) |p, i| drawTile(grid_start_x, grid_start_y, p, SNAKE_TAIL_TILE_COLORS[i%SNAKE_TAIL_TILE_COLORS.len]);
        }
        if (c.IsWindowResized()) {
            window_width = @intCast(c.GetScreenWidth());
            window_height = @intCast(c.GetScreenHeight());
        }
        try getKeyDirs(&dir_queue);
        if (started and !is_dead) {
            if (time_until_update > 0) {
                const delta = c.GetFrameTime();
                const d: u64 = @intFromFloat(@max(0, delta*std.time.ns_per_s));
                time_until_update = if (time_until_update >= d) time_until_update - d else 0;
                if (time_until_update > 0) continue;
            }
            time_until_update = NS_PER_FRAME;

            while (dir_queue.popOrNull()) |d| {
                const is_valid = switch (head_dir) {
                    .up,   .down  => d == .left or d == .right,
                    .left, .right => d == .down or d == .up
                };
                if (is_valid) head_dir = d;
            }
            if (std.meta.eql(parts.items[0], apple)) {
                // this will be set later by the update code
                try parts.append(undefined);
                apple = genAppleLoc(rand);
            }
            // update tail
            {var i: usize = parts.items.len-1; while (i >= 1) : (i -= 1) {
                parts.items[i] = parts.items[i - 1];
            }}
            // update head
            parts.items[0] = moveDir(head_dir, parts.items[0]);

            is_dead = blk: {
                for (parts.items[1..]) |p| if (std.meta.eql(parts.items[0], p)) break :blk true;
                break :blk false;
            };
        } else if (is_dead) {
            if (c.IsKeyPressed(c.KEY_R)) {
                dir_queue.clearAndFree();
                parts.clearAndFree();
                try parts.append(.{.x = GRID_WIDTH/2, .y = GRID_HEIGHT/2});
                started = false;
                time_until_update = 0;
                is_dead = false;
            } else if (c.IsKeyPressed(c.KEY_Q)) {
                break;
            }
        } else { // !started
            if (dir_queue.popOrNull()) |d| {
                started = true;
                head_dir = d;
                apple = genAppleLoc(rand);
            }
        }
    }
    c.CloseWindow();
}
