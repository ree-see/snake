const std = @import("std");
const core = @import("core");
const games = @import("games");

const t = std.testing;
const talloc = t.allocator;

const Bot = @This();

snake_idx: usize,

const init: Bot = .{
    .snake_idx = undefined,
};

fn isSafe(
    self: *Bot,
    game_state: *const games.TronGame,
    dir: core.Snake.Direction,
) bool {
    const s = game_state.snakes.slice();
    const snake = s.get(self.snake_idx);
    const body = snake.body.items;
    const head = body[0];
    const next_pos = core.nextPos(dir, head) orelse return false;
    return game_state.isPosAvailable(next_pos);
}

/// Chooses a safe forward or perpendicular turn for the bot's assigned snake.
pub fn decide(
    self: *Bot,
    game_state: *const games.TronGame,
) ?core.Snake.Direction {
    const s = game_state.snakes.slice();
    const snake = s.get(self.snake_idx);

    if (snake.is_dead == true) return null;

    if (isSafe(self, game_state, snake.direction))
        return snake.direction;

    switch (snake.direction) {
        .down, .up => { // compute left, right
            if (isSafe(self, game_state, .left))
                return .left;

            if (isSafe(self, game_state, .right))
                return .right;
        },
        .right, .left => { // compute down, up
            if (isSafe(self, game_state, .up))
                return .up;

            if (isSafe(self, game_state, .down))
                return .down;
        },
    }

    return null;
}

test "decide returns no input for a dead bot" {
    var game = games.TronGame.init;
    defer game.deinit(talloc);

    var snake = try core.Snake.initAt(talloc, .{ .x = 10, .y = 10 }, .right);
    snake.is_dead = true;
    try game.snakes.append(talloc, snake);

    var bot: Bot = .{ .snake_idx = 0 };
    try t.expectEqual(null, bot.decide(&game));
}

test "decide keeps moving forward when the next cell is available" {
    var game = games.TronGame.init;
    defer game.deinit(talloc);

    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 10, .y = 10 }, .right),
    );

    var bot: Bot = .{ .snake_idx = 0 };
    const decision = bot.decide(&game).?;
    try t.expectEqual(core.Snake.Direction.right, decision);
}

test "decide turns vertically moving bots left before right" {
    var game = games.TronGame.init;
    defer game.deinit(talloc);

    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 10, .y = 10 }, .up),
    );
    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 10, .y = 9 }, .up),
    );

    var bot: Bot = .{ .snake_idx = 0 };
    const decision = bot.decide(&game).?;
    try t.expectEqual(core.Snake.Direction.left, decision);
}

test "decide uses the remaining perpendicular direction when blocked" {
    var game = games.TronGame.init;
    defer game.deinit(talloc);

    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 10, .y = 10 }, .right),
    );
    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 11, .y = 10 }, .right),
    );
    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 10, .y = 9 }, .right),
    );

    var bot: Bot = .{ .snake_idx = 0 };
    const decision = bot.decide(&game).?;
    try t.expectEqual(core.Snake.Direction.down, decision);
}

test "decide returns no input when every direction is blocked" {
    var game = games.TronGame.init;
    defer game.deinit(talloc);

    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 0, .y = 0 }, .up),
    );
    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 1, .y = 0 }, .right),
    );

    var bot: Bot = .{ .snake_idx = 0 };
    try t.expectEqual(null, bot.decide(&game));
}
