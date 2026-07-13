const std = @import("std");

pub const GRID_WIDTH = 128;
pub const GRID_HEIGHT = 96;

pub fn gridCorner(direction: Snake.Direction) struct { Snake.Direction, Position } {
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

pub fn gridCenter() Position {
    const x = GRID_WIDTH / 2;
    const y = GRID_HEIGHT / 2;

    return Position{ .x = x, .y = y };
}

const Food = struct {
    pos: Position,

    pub fn new(rand: std.Random) Food {
        return Food{
            .pos = .{ .x = rand.intRangeLessThan(u8, 0, GRID_WIDTH - 1), .y = rand.intRangeLessThan(u8, 0, GRID_HEIGHT - 1) },
        };
    }
};

// Pure geometry over data, not methods on a fat object. TronGame's hot loops
// call these directly against SoA columns; Snake.next/contains delegate to them
// so the single-snake path (ClassicGame) and the many-snake SoA path share one
// implementation.
fn nextPos(direction: Snake.Direction, head: Position) ?Position {
    return switch (direction) {
        .up => if (head.y == 0) null else .{ .x = head.x, .y = head.y - 1 },
        .down => if (head.y == GRID_HEIGHT - 1) null else .{ .x = head.x, .y = head.y + 1 },
        .left => if (head.x == 0) null else .{ .x = head.x - 1, .y = head.y },
        .right => if (head.x == GRID_WIDTH - 1) null else .{ .x = head.x + 1, .y = head.y },
    };
}

fn bodyContains(body: []const Position, target: Position) bool {
    for (body) |pos| {
        if (std.meta.eql(pos, target)) return true;
    }
    return false;
}

pub fn setDirection(prev_dir: Snake.Direction, key_press: u8) Snake.Direction {
    return switch (key_press) {
        105 => if (prev_dir != .down) .up else .down,
        106 => if (prev_dir != .right) .left else .right,
        107 => if (prev_dir != .up) .down else .up,
        108 => if (prev_dir != .left) .right else .left,
        else => prev_dir,
    };
}

pub const Delta = struct {
    death: ?TronGame.DeathResult,
    nextPos: ?Position,

    const Header = packed struct {
        has_death: bool,
        has_killer: bool,
        has_pos: bool,
        _: u5 = 0,
    };

    // byte 1: header 00000 has_death, has_killer, has_pos
    // byte 2: death killer snake idx
    // byte 3: x pos
    // byte 4: y pos
    pub fn encode(d: Delta) [4]u8 {
        var payload: [4]u8 = undefined;
        var header: Header = .{
            .has_death = true,
            .has_killer = true,
            .has_pos = true,
        };

        if (d.death != null) {
            header.has_killer = if (d.death.?.killer != null) true else false;
        } else {
            header.has_death = false;
            header.has_killer = false;
        }
        header.has_pos = if (d.nextPos != null) true else false;

        for (0..4) |i| {
            switch (i) {
                0 => payload[i] = @bitCast(header),
                1 => payload[i] = if (header.has_killer) d.death.?.killer.? else 0,
                2 => payload[i] = if (header.has_pos) d.nextPos.?.x else 0,
                3 => payload[i] = if (header.has_pos) d.nextPos.?.y else 0,
                else => {},
            }
        }
        return payload;
    }

    test "encode Delta" {
        const t = std.testing;
        const delta = Delta{
            .death = .{
                .died = 1,
                .killer = 4,
            },
            .nextPos = .{ .x = 3, .y = 5 },
        };

        const encoded_delta = delta.encode();
        const expected: [4]u8 = .{ 0x07, 4, 3, 5 };

        try t.expectEqual(expected, encoded_delta);
    }
};

pub const TronGame = struct {
    // ---- Data-oriented layout ------------------------------------------------
    // The old shape was `snakes: [n]Snake` — an array of fat structs. Every tick,
    // checkBodyCollision / checkSelfCollision / advanceSnakes open with
    //     if (snake.is_dead) continue;
    // In AoS, reading that one bool drags the whole Snake (bool + direction +
    // kills + a ~24-byte ArrayList handle) into cache, one line per snake, just
    // to decide whether to skip it.
    //
    // MultiArrayList stores each field in its own parallel column, so the dead
    // gate scans a dense []bool: many snakes per cache line, and the hardware
    // prefetcher can stream it. We reach for MultiArrayList (not a fixed [n] SoA
    // struct) because the snake.io north star has a *dynamic* player count.
    //
    // The limit worth remembering: `body` is still an ArrayList — a pointer to a
    // per-snake heap allocation. Packing the handles contiguously does nothing
    // for the bodyContains() scan, which follows that pointer off to scattered
    // heap memory. Fixing the body scan is a separate, deeper redesign.
    state: GameState,
    snakes: std.MultiArrayList(Snake),
    delta: [n_snakes]Delta,

    pub const n_snakes: u8 = 5;
    // Indices into `snakes`, not pointers or usize: a u8 addresses the roster
    // with room to spare. (Kelley's "shrink the struct" half.)
    const DeathResult = struct { died: u8, killer: ?u8 };

    pub fn init(gpa: std.mem.Allocator) !TronGame {
        const direction_a, const pos_a = gridCorner(.down);
        const direction_b, const pos_b = gridCorner(.up);
        const direction_c, const pos_c = gridCorner(.left);
        const direction_d, const pos_d = gridCorner(.right);
        const pos_e = gridCenter();
        const direction_e: Snake.Direction = .left;

        var snakes: std.MultiArrayList(Snake) = .empty;
        try snakes.append(gpa, try Snake.initAt(gpa, pos_a, direction_a));
        try snakes.append(gpa, try Snake.initAt(gpa, pos_b, direction_b));
        try snakes.append(gpa, try Snake.initAt(gpa, pos_c, direction_c));
        try snakes.append(gpa, try Snake.initAt(gpa, pos_d, direction_d));
        try snakes.append(gpa, try Snake.initAt(gpa, pos_e, direction_e));

        return .{
            .state = .lobby,
            .snakes = snakes,
            .delta = undefined,
        };
    }

    pub fn deinit(self: *TronGame, gpa: std.mem.Allocator) void {
        // Each body owns its own heap allocation — free them before the columns.
        for (self.snakes.items(.body)) |*body| body.deinit(gpa);
        self.snakes.deinit(gpa);
    }

    pub fn encodeDeltas(self: *TronGame) [n_snakes * 4]u8 {
        var encoded_deltas: [n_snakes * 4]u8 = undefined;
        var j: usize = 0;
        for (0..n_snakes) |i| {
            const bytes = self.delta[i].encode();
            for (bytes) |byte| {
                encoded_deltas[j] = byte;
                j += 1;
            }
        }
        return encoded_deltas;
    }

    // Snapshot each live snake's next head cell; dead snakes are null.
    pub fn nextPositions(self: *TronGame) void {
        const s = self.snakes.slice();
        const dead = s.items(.is_dead);
        const dir = s.items(.direction);
        const body = s.items(.body);

        for (0..n_snakes) |i| {
            self.delta[i].nextPos = if (dead[i]) null else nextPos(dir[i], body[i].items[0]);
        }
    }

    // Two live heads aiming at the same cell: the one with fewer kills dies
    // (ties: the higher index dies), the other is credited the kill.
    pub fn checkH2HCollision(self: *TronGame) void {
        const positions = self.delta;
        const s = self.snakes.slice();
        const dead = s.items(.is_dead);
        const kills = s.items(.kills);

        for (positions, 0..) |maybe_a, i| {
            if (i == n_snakes - 1) break;
            const a = maybe_a.nextPos orelse continue;
            var j = i + 1;
            while (j < n_snakes) : (j += 1) {
                const b = positions[j].nextPos orelse continue;
                if (!std.meta.eql(a, b)) continue;

                if (kills[i] >= kills[j]) {
                    self.delta[j].death = .{ .died = @intCast(j), .killer = @intCast(i) };
                    dead[j] = true;
                } else {
                    self.delta[i].death = .{ .died = @intCast(i), .killer = @intCast(j) };
                    dead[i] = true;
                }
            }
        }
    }

    // A live head stepping into any snake's body dies; that snake gets the kill.
    pub fn checkBodyCollision(self: *TronGame) void {
        const s = self.snakes.slice();
        const dead = s.items(.is_dead);
        const body = s.items(.body);

        for (0..n_snakes) |i| {
            if (dead[i]) continue;
            const target = self.delta[i].nextPos orelse continue;
            for (0..n_snakes) |j| {
                if (i == j) continue;
                if (bodyContains(body[j].items, target)) {
                    self.delta[i].death = .{ .died = @intCast(i), .killer = @intCast(j) };
                    dead[i] = true;
                    break;
                }
            }
        }
    }

    // A live head with no legal next cell (wall) or stepping into itself dies,
    // uncredited.
    pub fn checkSelfCollision(self: *TronGame) void {
        const s = self.snakes.slice();
        const dead = s.items(.is_dead);
        const body = s.items(.body);

        for (0..n_snakes) |i| {
            if (dead[i]) continue;
            const target = self.delta[i].nextPos orelse {
                self.delta[i].death = .{ .died = @intCast(i), .killer = null };
                dead[i] = true;
                continue;
            };
            if (bodyContains(body[i].items, target)) {
                self.delta[i].death = .{ .died = @intCast(i), .killer = null };
                dead[i] = true;
            }
        }
    }

    pub fn applyDeaths(self: *TronGame) void {
        const s = self.snakes.slice();
        const dead = s.items(.is_dead);
        const kills = s.items(.kills);
        const body = s.items(.body);

        for (self.delta) |maybe_death| {
            const death = maybe_death.death orelse continue;
            dead[death.died] = true;
            body[death.died].clearRetainingCapacity();
            if (death.killer) |killer| kills[killer] += 1;
        }
    }

    pub fn advanceSnakes(self: *TronGame, gpa: std.mem.Allocator) !void {
        const s = self.snakes.slice();
        const dead = s.items(.is_dead);
        const body = s.items(.body);

        var dead_count: u8 = 0;
        for (0..n_snakes) |i| {
            if (dead[i]) {
                dead_count += 1;
                continue;
            }
            if (self.delta[i].nextPos) |target| {
                try body[i].insert(gpa, 0, target);
            }
        }
        if (dead_count == n_snakes - 1 or dead_count == n_snakes) self.state = .over;
    }

    pub fn resetDelta(self: *TronGame) void {
        self.nextPositions();
        for (0..n_snakes) |i| {
            self.delta[i].death = null;
        }
    }

    pub fn tick(self: *TronGame, gpa: std.mem.Allocator) !void {
        self.resetDelta();
        self.checkBodyCollision();
        self.checkH2HCollision();
        self.checkSelfCollision();
        self.applyDeaths();
        try self.advanceSnakes(gpa);
    }
};

pub const GameState = enum {
    lobby,
    running,
    paused,
    over,
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

    const Direction = enum {
        left,
        right,
        up,
        down,
    };

    pub fn init(gpa: std.mem.Allocator) !Snake {
        var body = std.ArrayList(Position).empty;
        try body.append(gpa, gridCenter());

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

    pub fn step(self: *Snake, gpa: std.mem.Allocator) !void {
        if (nextPos(self.direction, self.body.items[0])) |target|
            try self.addHead(gpa, target);
    }
};

// ===========================================================================
// Characterization tests for the simulation core.
//
// These pin the *current* behavior of the platform-agnostic model
// (Snake.next/step/contains, setDirection, gridCenter/clear) before the
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
    try expectEqual(@as(?Position, null), nextPos(snake.direction, snake.body.items[0]));

    // Down off the bottom row.
    snake.body.items[0] = .{ .x = 10, .y = GRID_HEIGHT - 1 };
    snake.direction = .down;
    try expectEqual(@as(?Position, null), nextPos(snake.direction, snake.body.items[0]));

    // Left off the first column.
    snake.body.items[0] = .{ .x = 0, .y = 10 };
    snake.direction = .left;
    try expectEqual(@as(?Position, null), nextPos(snake.direction, snake.body.items[0]));

    // Right off the last column.
    snake.body.items[0] = .{ .x = GRID_WIDTH - 1, .y = 10 };
    snake.direction = .right;
    try expectEqual(@as(?Position, null), nextPos(snake.direction, snake.body.items[0]));
}

test "next returns the adjacent cell for interior moves" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    snake.body.items[0] = .{ .x = 10, .y = 10 };

    snake.direction = .up;
    try expectEqual(@as(?Position, .{ .x = 10, .y = 9 }), nextPos(snake.direction, snake.body.items[0]));
    snake.direction = .down;
    try expectEqual(@as(?Position, .{ .x = 10, .y = 11 }), nextPos(snake.direction, snake.body.items[0]));
    snake.direction = .left;
    try expectEqual(@as(?Position, .{ .x = 9, .y = 10 }), nextPos(snake.direction, snake.body.items[0]));
    snake.direction = .right;
    try expectEqual(@as(?Position, .{ .x = 11, .y = 10 }), nextPos(snake.direction, snake.body.items[0]));
}

test "contains reports head, body, and misses" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    snake.body.items[0] = .{ .x = 32, .y = 16 }; // head
    try snake.body.append(gpa, .{ .x = 33, .y = 16 }); // a body segment

    try expect(bodyContains(snake.body.items, .{ .x = 32, .y = 16 })); // head hit
    try expect(bodyContains(snake.body.items, .{ .x = 33, .y = 16 })); // body hit
    try expect(!bodyContains(snake.body.items, .{ .x = 0, .y = 0 })); // miss
}

test "step into the wall annotates snake is dead and hit a wall" {
    const gpa = std.testing.allocator;
    var game = try TronGame.init(gpa);
    defer game.deinit(gpa);

    game.snakes.items(.direction)[0] = .left; // next() is null off the left edge
    game.resetDelta();
    game.checkSelfCollision();

    const death_res = game.delta[0].death;
    try std.testing.expectEqual(0, death_res.?.died);
}

test "step into own body ends the game" {
    const gpa = std.testing.allocator;
    var game = try TronGame.init(gpa);
    defer game.deinit(gpa);

    // A 2x2 loop: head at {10,10} moving right lands on the tail at {11,10}.
    const body = &game.snakes.items(.body)[0];
    body.clearRetainingCapacity();
    try body.append(gpa, .{ .x = 10, .y = 10 }); // head
    try body.append(gpa, .{ .x = 10, .y = 11 });
    try body.append(gpa, .{ .x = 11, .y = 11 });
    try body.append(gpa, .{ .x = 11, .y = 10 }); // tail (the cell we hit)
    game.snakes.items(.direction)[0] = .right;
    game.resetDelta();
    game.checkSelfCollision();

    const death_res = game.delta[0].death;
    try std.testing.expectEqual(0, death_res.?.died);
}

test "step grows the snakes every tick" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    snake.body.items[0] = .{ .x = 10, .y = 10 };
    snake.direction = .right;

    const len_before = snake.len();
    try snake.step(gpa);
    try expectEqual(len_before + 1, snake.len());
    try expectEqual(@as(Position, .{ .x = 11, .y = 10 }), snake.body.items[0]);
}

test "setDirection ignores reversals into self" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    // Key bytes: 105=up(i), 106=left(j), 107=down(k), 108=right(l).
    snake.direction = .right;
    var prev_dir = snake.direction;
    snake.direction = setDirection(prev_dir, 106); // left key while moving right -> ignored
    try expectEqual(Snake.Direction.right, snake.direction);

    snake.direction = .left;
    prev_dir = snake.direction;
    snake.direction = setDirection(prev_dir, 108); // right key while moving left -> ignored
    try expectEqual(Snake.Direction.left, snake.direction);

    snake.direction = .up;
    prev_dir = snake.direction;
    snake.direction = setDirection(prev_dir, 107); // down key while moving up -> ignored
    try expectEqual(Snake.Direction.up, snake.direction);

    snake.direction = .down;
    prev_dir = snake.direction;
    snake.direction = setDirection(prev_dir, 105); // up key while moving down -> ignored
    try expectEqual(Snake.Direction.down, snake.direction);

    // A perpendicular turn is still accepted.
    snake.direction = .right;
    prev_dir = snake.direction;
    snake.direction = setDirection(prev_dir, 105); // up key while moving right -> applied
    try expectEqual(Snake.Direction.up, snake.direction);
}

test "gridCenter is the middle of the board" {
    try expectEqual(@as(Position, .{ .x = GRID_WIDTH / 2, .y = GRID_HEIGHT / 2 }), gridCenter());
}

test "simple game tick test" {
    const gpa = std.testing.allocator;
    var game = try TronGame.init(gpa);
    defer game.deinit(gpa);

    try game.tick(gpa);

    try std.testing.expectEqual(2, game.snakes.items(.body)[0].items.len);
    try std.testing.expectEqual(2, game.snakes.items(.body)[1].items.len);
}

test "game tick annotate snake is dead" {
    const gpa = std.testing.allocator;
    var game = try TronGame.init(gpa);
    defer game.deinit(gpa);

    game.snakes.items(.body)[0].items[0] = .{ .x = 0, .y = 16 };
    game.snakes.items(.direction)[0] = .left; // next() is null off the left edge
    try game.tick(gpa);

    try expect(game.snakes.items(.is_dead)[0]);
}

test "game tick snakes dies check if dead snake body is gone" {
    const gpa = std.testing.allocator;
    var game = try TronGame.init(gpa);
    defer game.deinit(gpa);

    game.snakes.items(.body)[0].items[0] = .{ .x = 0, .y = 16 };
    game.snakes.items(.direction)[0] = .left; // next() is null off the left edge
    try game.tick(gpa);
    try game.tick(gpa);

    try expectEqual(0, game.snakes.items(.body)[0].items.len);
    try expect(!game.snakes.items(.is_dead)[1]);
}

test "advanceSnake sets game state to dead with one alive snake" {
    const gpa = std.testing.allocator;
    var game = try TronGame.init(gpa);
    defer game.deinit(gpa);

    while (game.state != .over) {
        try game.tick(gpa);
    }

    try std.testing.expectEqual(GameState.over, game.state);

    const s = game.snakes.slice();
    const dead = s.items(.is_dead);
    var dead_count: u4 = 0;
    for (dead) |is_dead| {
        if (is_dead) dead_count += 1;
    }

    try std.testing.expectEqual(5, dead_count);
}

test "collision with other snakes body" {
    const gpa = std.testing.allocator;
    var game = try TronGame.init(gpa);
    defer game.deinit(gpa);

    const bodies = game.snakes.items(.body);
    const dirs = game.snakes.items(.direction);

    bodies[0].items[0] = .{ .x = 0, .y = 0 };
    try bodies[0].append(gpa, .{ .x = 0, .y = 1 });
    try bodies[0].append(gpa, .{ .x = 0, .y = 2 });
    dirs[0] = .right;

    bodies[1].items[0] = .{ .x = 1, .y = 1 };
    try bodies[1].append(gpa, .{ .x = 2, .y = 1 });
    try bodies[1].append(gpa, .{ .x = 3, .y = 1 });
    dirs[1] = .left;

    try game.tick(gpa);

    try std.testing.expect(game.snakes.items(.is_dead)[1]);
    try std.testing.expectEqual(0, bodies[1].items.len);
}

test "collision with other snakes body adds to kill count" {
    const gpa = std.testing.allocator;
    var game = try TronGame.init(gpa);
    defer game.deinit(gpa);

    const bodies = game.snakes.items(.body);
    const dirs = game.snakes.items(.direction);

    bodies[0].items[0] = .{ .x = 0, .y = 0 };
    try bodies[0].append(gpa, .{ .x = 0, .y = 1 });
    try bodies[0].append(gpa, .{ .x = 0, .y = 2 });
    dirs[0] = .right;

    bodies[1].items[0] = .{ .x = 1, .y = 1 };
    try bodies[1].append(gpa, .{ .x = 2, .y = 1 });
    try bodies[1].append(gpa, .{ .x = 3, .y = 1 });
    dirs[1] = .left;

    try game.tick(gpa);

    try std.testing.expectEqual(1, game.snakes.items(.kills)[0]);
}

test "encodeDeltas packs every snake's delta into one flat byte buffer" {
    const gpa = std.testing.allocator;
    var game = try TronGame.init(gpa);
    defer game.deinit(gpa);

    game.delta[0] = .{ .death = .{ .died = 0, .killer = 1 }, .nextPos = .{ .x = 1, .y = 2 } };
    game.delta[1] = .{ .death = null, .nextPos = .{ .x = 5, .y = 6 } };
    game.delta[2] = .{ .death = .{ .died = 2, .killer = null }, .nextPos = null };
    game.delta[3] = .{ .death = null, .nextPos = null };
    game.delta[4] = .{ .death = .{ .died = 4, .killer = 0 }, .nextPos = .{ .x = 10, .y = 20 } };

    const encoded = game.encodeDeltas();
    const expected = [TronGame.n_snakes * 4]u8{
        0x07, 1, 1,  2,
        0x04, 0, 5,  6,
        0x01, 0, 0,  0,
        0x00, 0, 0,  0,
        0x07, 0, 10, 20,
    };

    try std.testing.expectEqual(expected, encoded);
}

test "collision h2h test" {
    const gpa = std.testing.allocator;
    var game = try TronGame.init(gpa);
    defer game.deinit(gpa);

    const bodies = game.snakes.items(.body);
    const dirs = game.snakes.items(.direction);
    const kills = game.snakes.items(.kills);

    kills[1] = 1;

    bodies[0].items[0] = .{ .x = 0, .y = 0 };
    dirs[0] = .right;

    bodies[1].items[0] = .{ .x = 2, .y = 0 };
    dirs[1] = .left;

    try game.tick(gpa);

    try std.testing.expect(game.snakes.items(.is_dead)[0]);
    try std.testing.expectEqual(2, game.snakes.items(.kills)[1]);
}

pub const ClassicGame = struct {
    score: u8,
    snake: Snake,
    food: Food,
    state: GameState,

    pub fn init(gpa: std.mem.Allocator, rand: std.Random) !ClassicGame {
        const snake = try Snake.init(gpa);
        const food = Food.new(rand);
        const state = GameState.running;

        return .{ .score = 0, .snake = snake, .food = food, .state = state };
    }

    pub fn deinit(self: *ClassicGame, gpa: std.mem.Allocator) void {
        self.snake.deinit(gpa);
    }

    pub fn spawnFood(self: *ClassicGame, rand: std.Random) ?Food {
        // check if board is full with snakes body
        if (self.snake.len() == GRID_HEIGHT * GRID_WIDTH) return null;
        var new_food = Food.new(rand);
        // generate new food pos thats not the snakes body
        while (bodyContains(self.snake.body.items, new_food.pos)) {
            new_food = Food.new(rand);
        }

        return new_food;
    }

    pub fn tick(self: *ClassicGame, gpa: std.mem.Allocator, rand: std.Random) !void {
        if (nextPos(self.snake.direction, self.snake.body.items[0])) |next_pos| {
            if (bodyContains(self.snake.body.items, next_pos)) {
                self.state = .over;
            }
            try self.snake.addHead(gpa, next_pos);

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
};

test "classic snake movement" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = try ClassicGame.init(gpa, rand);
    defer game.deinit(gpa);

    const len_before = game.snake.len();
    try game.tick(gpa, rand);

    try std.testing.expectEqual(len_before, game.snake.len());
}

test "classic snake growth by eating" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try ClassicGame.init(gpa, rand);
    defer game.deinit(gpa);
    const center = gridCenter();

    game.food.pos.x = center.x + 1;
    game.food.pos.y = center.y;

    try game.tick(gpa, rand);

    try std.testing.expectEqual(1, game.score);
    try std.testing.expectEqual(2, game.snake.len());
}

test "food is respawning after being eaten" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try ClassicGame.init(gpa, rand);
    defer game.deinit(gpa);
    const center = gridCenter();

    game.food.pos.x = center.x + 1;
    game.food.pos.y = center.y;

    const food_before = game.food;

    try game.tick(gpa, rand);

    try std.testing.expect(!std.meta.eql(food_before.pos, game.food.pos));
}

test "classic game tick mutates game state if snakes dies" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try ClassicGame.init(gpa, rand);
    defer game.deinit(gpa);

    game.snake.body.items[0] = .{ .x = 0, .y = 16 };
    game.snake.direction = .left; // next() is null off the left edge
    try game.tick(gpa, rand);

    try std.testing.expectEqual(GameState.over, game.state);
}

test "classic game spawns food free from snakes body" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try ClassicGame.init(gpa, rand);
    defer game.deinit(gpa);
    game.snake.body.items[0] = Position{
        .x = 0,
        .y = GRID_WIDTH - 1,
    };
    game.snake.direction = .left;

    for (0..GRID_WIDTH / 3) |x| {
        for (1..GRID_HEIGHT - 1) |y| {
            const pos = Position{ .x = @intCast(x), .y = @intCast(y) };
            try game.snake.body.append(gpa, pos);
        }
    }
    const new_food = game.spawnFood(rand).?;

    try std.testing.expect(!bodyContains(game.snake.body.items, new_food.pos));
}
