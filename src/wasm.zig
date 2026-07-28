const std = @import("std");
const core = @import("core");
const games = @import("games");

var game: games.ClassicGame = undefined;
var initialized = false;
var prng: std.Random.DefaultPrng = undefined;

/// Resets the process-global Classic game with caller-provided random seed material.
export fn init(seed: u64) void {
    const walloc = std.heap.wasm_allocator;
    if (initialized) game.deinit(walloc);

    prng = std.Random.DefaultPrng.init(seed);
    game = games.ClassicGame.init(walloc, prng.random()) catch @panic("OOM error");
    initialized = true;
}

/// Advances one Classic frame and returns the numeric game state.
export fn tick() u8 {
    const walloc = std.heap.wasm_allocator;
    game.tick(walloc, prng.random()) catch @panic("OOM error");
    return @intFromEnum(game.state);
}

/// Applies a supported i/j/k/l direction input to the global game.
export fn setDirection(key_press: u8) void {
    const curr_dir = game.snake.direction;
    const new_dir = core.dirFromKeyPress(key_press) catch return;
    game.snake.direction = core.setDirection(curr_dir, new_dir);
}

/// Returns the current body length for use with `getSnakePtr`.
export fn getSnakeLength() usize {
    return game.snake.len();
}

/// Returns the linear-memory address of the current snake body positions.
///
/// Callers must reacquire this pointer after ticks because the body may reallocate.
export fn getSnakePtr() usize {
    return @intFromPtr(game.snake.body.items.ptr);
}

/// Returns the current Classic score.
export fn getScore() u16 {
    return game.score;
}

/// Returns the food column in the global Classic game.
export fn getFoodPosX() u16 {
    return game.food.pos.x;
}

/// Returns the food row in the global Classic game.
export fn getFoodPosY() u16 {
    return game.food.pos.y;
}

/// Returns the numeric Classic game state without advancing the simulation.
export fn getGameState() u8 {
    return @intFromEnum(game.state);
}
