const std = @import("std");
const core = @import("core");

var snake: core.Snake = undefined;
var game: core.Game = undefined;
var food: core.Food = undefined;
var prng: std.Random.DefaultPrng = undefined;

export fn init(seed: u64) void {
    const gpa = std.heap.wasm_allocator;
    prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    game = .{ .score = 0, .state = .running };
    food = core.Food.new(rand);
    snake = core.Snake.init(gpa) catch @panic("OOM error");
}

export fn tick() u8 {
    const gpa = std.heap.wasm_allocator;
    const rand = prng.random();
    const step_result = snake.step(gpa, &food) catch @panic("OOM error");

    if (step_result == core.GameState.food_ate) {
        game.score += 1;
        food = core.Food.new(rand);
    }

    return @intFromEnum(step_result);
}

export fn setDirection(key_press: u8) void {
    snake.setDirection(key_press);
}

export fn getSnakeLength() usize {
    return snake.body.items.len;
}

export fn getSnakePtr() usize {
    return @intFromPtr(snake.body.items.ptr);
}

export fn getScore() u8 {
    return game.score;
}

export fn getFoodPosX() u8 {
    return food.pos.x;
}

export fn getFoodPosY() u8 {
    return food.pos.y;
}
