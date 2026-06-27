const std = @import("std");
const core = @import("core");

var snake: core.Snake = undefined;
var game: core.Game = undefined;
var food: core.Food = undefined;

export fn init(seed: u64) void {
    const gpa = std.heap.wasm_allocator;
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    game = .{ .score = 0, .state = .running };
    food = core.Food.new(rand);
    snake = core.Snake.init(gpa) catch @panic("OOM error");
}
