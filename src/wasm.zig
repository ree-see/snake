const std = @import("std");
const core = @import("core");
const games = @import("games");

var game: games.TronGame = undefined;

export fn init() void {
    const walloc = std.heap.wasm_allocator;
    game = games.TronGame.init(walloc, games.Spawn.init()) catch @panic("OOM error");
}

export fn tick() void {
    const walloc = std.heap.wasm_allocator;
    game.tick(walloc) catch @panic("OOM error");
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
