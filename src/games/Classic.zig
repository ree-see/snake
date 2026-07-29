const std = @import("std");
const core = @import("core");
const games = @import("games.zig");

const t = std.testing;
const talloc = t.allocator;
const tio = t.io;

const Classic = @This();

/// Single-player Snake state with food, scoring, and tail removal.
score: u16,
state: games.GameState,
snake: core.Snake,
food: Food,

pub const Food = struct {
    pos: core.Position,

    pub fn new(rand: std.Random) Food {
        return Food{
            .pos = .{
                .x = rand.intRangeLessThan(u8, 0, core.GRID_WIDTH - 1),
                .y = rand.intRangeLessThan(u8, 0, core.GRID_HEIGHT - 1),
            },
        };
    }
};

/// Creates a running Classic game with a centered snake and random food.
pub fn init(alloc: std.mem.Allocator, rand: std.Random) !games.Classic {
    const snake = try core.Snake.init(alloc);
    const state: games.GameState = .running;
    const food = Food.new(rand);

    return .{
        .score = 0,
        .snake = snake,
        .food = food,
        .state = state,
    };
}

/// Releases the owned snake body allocation.
pub fn deinit(self: *Classic, alloc: std.mem.Allocator) void {
    self.snake.deinit(alloc);
}

/// Returns an unoccupied food cell, or null when the snake fills the board.
pub fn spawnFood(self: *Classic, rand: std.Random) ?Food {
    // check if board is full with snakes body
    if (self.snake.len() == core.GRID_HEIGHT * core.GRID_WIDTH) return null;
    var new_food = Food.new(rand);
    // generate new food pos thats not the snakes body
    while (core.bodyContains(self.snake.body.items, new_food.pos)) {
        new_food = Food.new(rand);
    }

    return new_food;
}

/// Advances one Classic frame, growing on food and ending on a wall or self hit.
pub fn tick(
    self: *Classic,
    alloc: std.mem.Allocator,
    rand: std.Random,
) !void {
    if (core.nextPos(self.snake.direction, self.snake.body.items[0])) |next_pos| {
        if (core.bodyContains(self.snake.body.items, next_pos)) {
            self.state = .over;
        }

        try self.snake.addHead(alloc, next_pos);

        if (std.meta.eql(next_pos, self.food.pos)) {
            self.score += 1;

            if (self.spawnFood(rand)) |food| self.food = food else self.state = .over;
        } else {
            self.snake.removeTail();
        }
    } else {
        self.state = .over;
    }
}
test "classic snake movement" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = try Classic.init(talloc, rand);
    defer game.deinit(talloc);

    const len_before = game.snake.len();
    try game.tick(talloc, rand);

    try t.expectEqual(len_before, game.snake.len());
}

test "classic snake growth by eating" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try Classic.init(talloc, rand);

    game.food.pos.x = core.center.x + 1;
    game.food.pos.y = core.center.y;

    try game.tick(talloc, rand);

    try t.expectEqual(1, game.score);
    try t.expectEqual(2, game.snake.len());
}

test "food is respawning after being eaten" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try Classic.init(talloc, rand);
    defer game.deinit(talloc);
    const center = core.gridCenter();

    game.food.pos.x = center.x + 1;
    game.food.pos.y = center.y;

    const food_before = game.food;
    try t.expect(!std.meta.eql(food_before.pos, game.food.pos));
}

test "classic game tick mutates game state if snakes dies" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try Classic.init(talloc, rand);
    defer game.deinit(talloc);

    game.snake.body.items[0] = .{ .x = 0, .y = 16 };
    game.snake.direction = .left; // next() is null off the left edge
    try game.tick(talloc, rand);

    try t.expectEqual(games.GameState.over, game.state);
}

test "classic game spawns food free from snakes body" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    const game = Classic.init(talloc, rand);
    defer game.deinit(talloc);
    game.snake.body.items[0] = .{ .x = 0, .y = core.GRID_WIDTH - 1 };
    game.snake.direction = .left;

    for (0..core.GRID_WIDTH / 3) |x| {
        for (0..core.GRID_HEIGHT / 3) |y| {
            const pos: core.Position = .{ .x = @intCast(x), .y = @intCast(y) };
            try game.snake.body.append(talloc, pos);
        }
    }
    const new_food = game.spawnFood(rand).?;

    try t.expect(!core.bodyContains(game.snake.body.items, new_food.pos));
}
