const std = @import("std");
const core = @import("core");

var snake: core.Snake = undefined;
var game: core.Game = undefined;

export fn init() void {
    const gpa = std.heap.wasm_allocator;

    game = .{ .score = 0, .state = .running };
    snake = core.Snake.init(gpa) catch @panic("OOM error");
}

export fn tick() u8 {
    const gpa = std.heap.wasm_allocator;
    const step_result = snake.step(gpa) catch @panic("OOM error");

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
