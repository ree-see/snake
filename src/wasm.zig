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
    game.snakes[idx].setDirection(key_press);
}

export fn getSnakeLength(idx: usize) usize {
    return game.snakes[idx].len();
}

export fn getSnakePtr(idx: usize) usize {
    return @intFromPtr(game.snakes[idx].body.items.ptr);
}

export fn getGameState() u8 {
    return @intFromEnum(game.state);
}
