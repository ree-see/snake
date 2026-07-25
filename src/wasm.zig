const std = @import("std");
const core = @import("core");
const games = @import("games");

var game: games.ClassicGame = undefined;
var initialized = false;
var prng: std.Random.DefaultPrng = undefined;

export fn init(seed: u64) void {
    const walloc = std.heap.wasm_allocator;
    if (initialized) game.deinit(walloc);

    prng = std.Random.DefaultPrng.init(seed);
    game = games.ClassicGame.init(walloc, prng.random()) catch @panic("OOM error");
    initialized = true;
}

export fn tick() u8 {
    const walloc = std.heap.wasm_allocator;
    game.tick(walloc, prng.random()) catch @panic("OOM error");
    return @intFromEnum(game.state);
}

export fn setDirection(key_press: u8) void {
    const curr_dir = game.snake.direction;
    const new_dir = core.dirFromKeyPress(key_press) catch return;
    game.snake.direction = core.setDirection(curr_dir, new_dir);
}

export fn getSnakeLength() usize {
    return game.snake.len();
}

export fn getSnakePtr() usize {
    return @intFromPtr(game.snake.body.items.ptr);
}

export fn getScore() u8 {
    return game.score;
}

export fn getFoodPosX() u32 {
    return game.food.pos.x;
}

export fn getFoodPosY() u32 {
    return game.food.pos.y;
}

export fn getGameState() u8 {
    return @intFromEnum(game.state);
}
