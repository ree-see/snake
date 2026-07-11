const std = @import("std");
const core = @import("core");

var game: core.TronGame = undefined;

export fn init() void {
    const gpa = std.heap.wasm_allocator;
    game = core.TronGame.init(gpa) catch @panic("OOM error");
}

export fn tick() void {
    const gpa = std.heap.wasm_allocator;
    game.tick(gpa) catch @panic("OOM error");
}

export fn setDirection(idx: usize, key_press: u8) void {
    const s = game.snakes.slice();
    const dirs = s.items(.direction);
    const prev_dir = dirs[idx];
    dirs[idx] = core.setDirection(prev_dir, key_press);
}

export fn getSnakeLength(idx: usize) usize {
    const s = game.snakes.slice();
    const bodies = s.items(.body);
    return bodies[idx].items.len;
}

export fn getSnakePtr(idx: usize) usize {
    const s = game.snakes.slice();
    const bodies = s.items(.body);

    return @intFromPtr(bodies[idx].items.ptr);
}

export fn getGameState() u8 {
    return @intFromEnum(game.state);
}
