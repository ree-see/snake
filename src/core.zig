const std = @import("std");

pub const GRID_WIDTH = 128;
pub const GRID_HEIGHT = 96;

pub fn grid_corner(direction: Direction) struct { Direction, Position } {
    const top_left = Position{ .x = 0, .y = 0 };
    const top_right = Position{ .x = GRID_WIDTH - 1, .y = 0 };
    const bottom_left = Position{ .x = 0, .y = GRID_HEIGHT - 1 };
    const bottom_right = Position{ .x = GRID_WIDTH - 1, .y = GRID_HEIGHT - 1 };

    switch (direction) {
        .left => return .{ .left, top_right },
        .right => return .{ .right, bottom_left },
        .up => return .{ .up, bottom_right },
        .down => return .{ .down, top_left },
    }
}

pub fn grid_center() Position {
    const x = GRID_WIDTH / 2;
    const y = GRID_HEIGHT / 2;

    return Position{ .x = x, .y = y };
}
pub const Game = struct {
    score: u8,
    state: GameState,
    snakes: [5]Snake,

    const CollisionError = enum {
        H2HCollision,
        BodyCollision,
    };

    const Pair = struct { usize, usize };

    pub fn init(gpa: std.mem.Allocator) !Game {
        const direction_a, const pos_a = grid_corner(.down);
        const direction_b, const pos_b = grid_corner(.up);
        const direction_c, const pos_c = grid_corner(.left);
        const direction_d, const pos_d = grid_corner(.right);
        const pos_e = grid_center();
        const direction_e: Direction = .left;
        const snake_a = try Snake.initAt(gpa, pos_a, direction_a);
        const snake_b = try Snake.initAt(gpa, pos_b, direction_b);
        const snake_c = try Snake.initAt(gpa, pos_c, direction_c);
        const snake_d = try Snake.initAt(gpa, pos_d, direction_d);
        const snake_e = try Snake.initAt(gpa, pos_e, direction_e);

        var snakes: [5]Snake = undefined;
        snakes[0] = snake_a;
        snakes[1] = snake_b;
        snakes[2] = snake_c;
        snakes[3] = snake_d;
        snakes[4] = snake_e;
        return .{ .score = 0, .state = .running, .snakes = snakes };
    }

    pub fn deinit(self: *Game, gpa: std.mem.Allocator) void {
        self.snakes[0].deinit(gpa);
        self.snakes[1].deinit(gpa);
        self.snakes[2].deinit(gpa);
        self.snakes[3].deinit(gpa);
        self.snakes[4].deinit(gpa);
    }

    // collect all next snakes positions
    pub fn nextPositions(self: *Game) [self.snakes.len]?Position {
        var targets: [self.snakes.len]?Position = undefined;
        for (&self.snakes, 0..) |*snake, i| {
            if (snake.is_dead) continue;
            targets[i] = snake.next();
        }

        return targets;
    }

    // check if any of the next positions are the same and if there are then return the pairs
    pub fn checkH2HCollision(self: *Game) [self.snakes.len / 2]?Pair {
        // thought of an edge case this doesn't handle very rare but if 2 pairs of snakes are about h2h collide
        const positions = self.nextPositions();
        const max_collisions = self.snakes.len / 2;
        var collisions: [max_collisions]?Pair = [_]?Pair{null} ** max_collisions;
        var count: usize = 0;
        for (positions, 0..) |pos, i| {
            var j = i + 1;
            if (i == positions.len - 1) break;
            while (j <= positions.len - 1) {
                const next_pos = positions[j];
                if (pos == null or next_pos == null) {
                    j += 1;
                    continue;
                }
                if (std.meta.eql(pos.?, next_pos.?)) {
                    collisions[count] = .{ i, j };
                    j += 1;
                    count += 1;
                } else {
                    j += 1;
                }
            }
        }
        return collisions;
    }

    pub fn tick(self: *Game, gpa: std.mem.Allocator) !void {
        for (self.checkH2HCollision()) |pair| {
            const idx_a, const idx_b = pair orelse continue;

            var snake_a = &self.snakes[idx_a];
            var snake_b = &self.snakes[idx_b];

            if (snake_a.kills == snake_b.kills) {
                snake_b.kill();
                snake_a.kills += 1;
            }

            if (snake_a.kills > snake_b.kills) {
                snake_b.kill();
                snake_a.kills += 1;
            }
            if (snake_a.kills < snake_b.kills) {
                snake_a.kill();
                snake_b.kills += 1;
            }
        }

        for (&self.snakes, 0..) |*curr_snake, i| {
            if (curr_snake.is_dead) continue;
            // check for body collision
            for (&self.snakes, 0..) |*snake, j| {
                const curr_snake_target = curr_snake.next() orelse continue;
                if (i == j) continue; // skip outer loop snake
                if (snake.contains(curr_snake_target)) {
                    curr_snake.is_dead = true;
                    curr_snake.clearBody();
                    snake.kills += 1;
                    break;
                }
            }

            if (curr_snake.is_dead) continue;
            const result = try curr_snake.step(gpa);
            if (result == .over) {
                curr_snake.kill();
            }
        }
    }
};

pub const GameState = enum {
    running,
    paused,
    over,
};

const Direction = enum {
    left,
    right,
    up,
    down,
};

const Position = extern struct {
    x: u8,
    y: u8,
};

pub const Snake = struct {
    is_dead: bool,
    direction: Direction,
    kills: u8,
    body: std.ArrayList(Position),

    pub fn init(gpa: std.mem.Allocator) !Snake {
        var body = std.ArrayList(Position).empty;
        try body.append(gpa, .{ .x = 0, .y = 0 });

        return .{
            .body = body,
            .direction = .right,
            .is_dead = false,
            .kills = 0,
        };
    }

    pub fn initAt(gpa: std.mem.Allocator, starting_pos: Position, starting_direciton: Direction) !Snake {
        var body = std.ArrayList(Position).empty;
        try body.append(gpa, starting_pos);

        return .{
            .body = body,
            .direction = starting_direciton,
            .is_dead = false,
            .kills = 0,
        };
    }

    pub fn deinit(self: *Snake, gpa: std.mem.Allocator) void {
        self.body.deinit(gpa);
    }

    pub fn kill(self: *Snake) void {
        self.is_dead = true;
        self.clearBody();
    }

    // returns null for illegal step position on the grid
    // returns position for legal step position on the grid
    pub fn next(self: *Snake) ?Position {
        const head = self.body.items[0];
        const next_pos: ?Position = switch (self.direction) {
            .up => if (head.y == 0) null else Position{ .x = head.x, .y = head.y - 1 },
            .down => if (head.y == GRID_HEIGHT - 1) null else Position{ .x = head.x, .y = head.y + 1 },
            .left => if (head.x == 0) null else Position{ .x = head.x - 1, .y = head.y },
            .right => if (head.x == GRID_WIDTH - 1) null else Position{ .x = head.x + 1, .y = head.y },
        };

        return next_pos;
    }

    pub fn contains(self: *Snake, target: Position) bool {
        for (self.body.items) |pos| {
            if (std.meta.eql(pos, target)) return true;
        }
        return false;
    }

    pub fn setDirection(self: *Snake, key_press: u8) void {
        switch (key_press) {
            105 => {
                if (self.direction != .down) {
                    self.direction = .up;
                }
            },
            106 => {
                if (self.direction != .right) {
                    self.direction = .left;
                }
            },
            107 => {
                if (self.direction != .up) {
                    self.direction = .down;
                }
            },
            108 => {
                if (self.direction != .left) {
                    self.direction = .right;
                }
            },
            else => {},
        }
    }

    pub fn addHead(self: *Snake, gpa: std.mem.Allocator, next_pos: Position) !void {
        try self.body.insert(gpa, 0, next_pos);
    }

    pub fn removeTail(self: *Snake) void {
        _ = self.body.pop();
    }

    pub fn len(self: *Snake) usize {
        return self.body.items.len;
    }

    pub fn clearBody(self: *Snake) void {
        self.body.clearRetainingCapacity();
    }

    pub fn step(self: *Snake, gpa: std.mem.Allocator) !GameState {
        const target = self.next() orelse return .over; // if off grid returns game over if not returns a pos
        if (self.contains(target)) return .over; // self collision check
        try self.addHead(gpa, target);
        return .running;
    }
};

// ===========================================================================
// Characterization tests for the simulation core.
//
// These pin the *current* behavior of the platform-agnostic model
// (Snake.next/step/contains, setDirection, grid_center/clear) before the
// planned WASM extraction refactor moves this logic. They intentionally drive
// the model directly (setting `direction` / `body` instead of going through
// the terminal loop) so they need no TTY. Run with `zig test src/main.zig`
// (or `zig build test`); filter one with `--test-filter "<name substring>"`.
// ===========================================================================

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "next returns null at every wall edge" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    // Up off the top row.
    snake.body.items[0] = .{ .x = 10, .y = 0 };
    snake.direction = .up;
    try expectEqual(@as(?Position, null), snake.next());

    // Down off the bottom row.
    snake.body.items[0] = .{ .x = 10, .y = GRID_HEIGHT - 1 };
    snake.direction = .down;
    try expectEqual(@as(?Position, null), snake.next());

    // Left off the first column.
    snake.body.items[0] = .{ .x = 0, .y = 10 };
    snake.direction = .left;
    try expectEqual(@as(?Position, null), snake.next());

    // Right off the last column.
    snake.body.items[0] = .{ .x = GRID_WIDTH - 1, .y = 10 };
    snake.direction = .right;
    try expectEqual(@as(?Position, null), snake.next());
}

test "next returns the adjacent cell for interior moves" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    snake.body.items[0] = .{ .x = 10, .y = 10 };

    snake.direction = .up;
    try expectEqual(@as(?Position, .{ .x = 10, .y = 9 }), snake.next());
    snake.direction = .down;
    try expectEqual(@as(?Position, .{ .x = 10, .y = 11 }), snake.next());
    snake.direction = .left;
    try expectEqual(@as(?Position, .{ .x = 9, .y = 10 }), snake.next());
    snake.direction = .right;
    try expectEqual(@as(?Position, .{ .x = 11, .y = 10 }), snake.next());
}

test "contains reports head, body, and misses" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    snake.body.items[0] = .{ .x = 32, .y = 16 }; // head
    try snake.body.append(gpa, .{ .x = 33, .y = 16 }); // a body segment

    try expect(snake.contains(.{ .x = 32, .y = 16 })); // head hit
    try expect(snake.contains(.{ .x = 33, .y = 16 })); // body hit
    try expect(!snake.contains(.{ .x = 0, .y = 0 })); // miss
}

test "step into the wall ends the game" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    snake.body.items[0] = .{ .x = 0, .y = 16 };
    snake.direction = .left; // next() is null off the left edge

    try expectEqual(GameState.over, try snake.step(gpa));
}

test "step into own body ends the game" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    // A 2x2 loop: head at {10,10} moving right lands on the tail at {11,10}.
    snake.clearBody();
    try snake.body.append(gpa, .{ .x = 10, .y = 10 }); // head
    try snake.body.append(gpa, .{ .x = 10, .y = 11 });
    try snake.body.append(gpa, .{ .x = 11, .y = 11 });
    try snake.body.append(gpa, .{ .x = 11, .y = 10 }); // tail (the cell we hit)
    snake.direction = .right;

    try expectEqual(GameState.over, try snake.step(gpa));
}

test "step grows the snakes every tick" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    snake.body.items[0] = .{ .x = 10, .y = 10 };
    snake.direction = .right;

    const len_before = snake.len();
    try expectEqual(GameState.running, try snake.step(gpa));
    try expectEqual(len_before + 1, snake.len()); // tail popped -> same length
    try expectEqual(@as(Position, .{ .x = 11, .y = 10 }), snake.body.items[0]);
}

test "setDirection ignores reversals into self" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    // Key bytes: 105=up(i), 106=left(j), 107=down(k), 108=right(l).
    snake.direction = .right;
    snake.setDirection(106); // left key while moving right -> ignored
    try expectEqual(Direction.right, snake.direction);

    snake.direction = .left;
    snake.setDirection(108); // right key while moving left -> ignored
    try expectEqual(Direction.left, snake.direction);

    snake.direction = .up;
    snake.setDirection(107); // down key while moving up -> ignored
    try expectEqual(Direction.up, snake.direction);

    snake.direction = .down;
    snake.setDirection(105); // up key while moving down -> ignored
    try expectEqual(Direction.down, snake.direction);

    // A perpendicular turn is still accepted.
    snake.direction = .right;
    snake.setDirection(105); // up key while moving right -> applied
    try expectEqual(Direction.up, snake.direction);
}

test "grid_center is the middle of the board" {
    try expectEqual(@as(Position, .{ .x = GRID_WIDTH / 2, .y = GRID_HEIGHT / 2 }), grid_center());
}

test "simple game tick test" {
    const gpa = std.testing.allocator;
    var game = try Game.init(gpa);
    defer game.deinit(gpa);

    try game.tick(gpa);

    try std.testing.expectEqual(2, game.snakes[0].len());
    try std.testing.expectEqual(2, game.snakes[1].len());
}

test "game tick annotate snake is dead when step returns game over" {
    const gpa = std.testing.allocator;
    var game = try Game.init(gpa);
    defer game.deinit(gpa);

    game.snakes[0].body.items[0] = .{ .x = 0, .y = 16 };
    game.snakes[0].direction = .left; // next() is null off the left edge
    try game.tick(gpa);

    try expect(game.snakes[0].is_dead);
}

test "game tick snakes dies check if dead snake body is gone" {
    const gpa = std.testing.allocator;
    var game = try Game.init(gpa);
    defer game.deinit(gpa);

    game.snakes[0].body.items[0] = .{ .x = 0, .y = 16 };
    game.snakes[0].direction = .left; // next() is null off the left edge
    try game.tick(gpa);
    try game.tick(gpa);

    try expectEqual(0, game.snakes[0].len());
    try expect(!game.snakes[1].is_dead);
}

test "collision with other snakes body" {
    const gpa = std.testing.allocator;
    var game = try Game.init(gpa);
    defer game.deinit(gpa);

    var snake_a = &game.snakes[0];
    var snake_b = &game.snakes[1];

    snake_a.body.items[0] = .{ .x = 0, .y = 0 };
    try snake_a.body.append(gpa, .{ .x = 0, .y = 1 });
    try snake_a.body.append(gpa, .{ .x = 0, .y = 2 });
    snake_a.direction = .right;

    snake_b.body.items[0] = .{ .x = 1, .y = 1 };
    try snake_b.body.append(gpa, .{ .x = 2, .y = 1 });
    try snake_b.body.append(gpa, .{ .x = 3, .y = 1 });
    snake_b.direction = .left;

    try game.tick(gpa);

    try std.testing.expect(snake_b.is_dead);
    try std.testing.expectEqual(0, snake_b.len());
}

test "collision with other snakes body adds to kill count" {
    const gpa = std.testing.allocator;
    var game = try Game.init(gpa);
    defer game.deinit(gpa);

    var snake_a = &game.snakes[0];
    var snake_b = &game.snakes[1];

    snake_a.body.items[0] = .{ .x = 0, .y = 0 };
    try snake_a.body.append(gpa, .{ .x = 0, .y = 1 });
    try snake_a.body.append(gpa, .{ .x = 0, .y = 2 });
    snake_a.direction = .right;

    snake_b.body.items[0] = .{ .x = 1, .y = 1 };
    try snake_b.body.append(gpa, .{ .x = 2, .y = 1 });
    try snake_b.body.append(gpa, .{ .x = 3, .y = 1 });
    snake_b.direction = .left;

    try game.tick(gpa);

    try std.testing.expectEqual(1, snake_a.kills);
}

test "collision h2h test" {
    const gpa = std.testing.allocator;
    var game = try Game.init(gpa);
    defer game.deinit(gpa);

    var snake_a = &game.snakes[0];
    var snake_b = &game.snakes[1];

    snake_b.kills = 1;

    snake_a.body.items[0] = .{ .x = 0, .y = 0 };
    snake_a.direction = .right;

    snake_b.body.items[0] = .{ .x = 2, .y = 0 };
    snake_b.direction = .left;

    try game.tick(gpa);

    try std.testing.expect(snake_a.is_dead);
    try std.testing.expectEqual(2, snake_b.kills);
}
