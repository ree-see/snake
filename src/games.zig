const std = @import("std");
const core = @import("core");

const t = std.testing;
const tio = t.io;
const talloc = t.allocator;

pub const GameState = enum {
    lobby,
    running,
    paused,
    over,
};

const Food = struct {
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

pub const Spawn = struct {
    pos: core.Position,
    direction: core.Snake.Direction,

    pub fn new(rand: std.Random) !Spawn {
        const x = rand.intRangeLessThan(u8, 0, core.GRID_WIDTH - 5);
        const y = rand.intRangeLessThan(u8, 0, core.GRID_HEIGHT - 5);
        const dir = try core.dirFromKeyPress(rand.intRangeLessThan(u8, 105, 109));

        return .{
            .pos = .{
                .x = x,
                .y = y,
            },
            .direction = dir,
        };
    }
};

pub const TronGame = struct {
    state: GameState,
    snakes: std.MultiArrayList(core.Snake),
    deltas: std.ArrayList(Delta),

    const DeathResult = struct { died: u8, killer: ?u8 };

    pub const init: TronGame = .{
        .state = .lobby,
        .snakes = .empty,
        .deltas = .empty,
    };

    pub fn deinit(self: *TronGame, alloc: std.mem.Allocator) void {
        // Each body owns its own heap allocation — free them before the columns.
        for (self.snakes.items(.body)) |*body| body.deinit(alloc);
        self.snakes.deinit(alloc);
        self.deltas.deinit(alloc);
    }

    pub fn isPosAvailable(self: *const TronGame, pos: core.Position) bool {
        const s = self.snakes.slice();
        const bodies = s.items(.body);
        for (bodies) |snakes_body| {
            if (core.bodyContains(snakes_body.items, pos)) return false;
        }
        return true;
    }

    pub fn spawnSnake(
        self: *TronGame,
        alloc: std.mem.Allocator,
        rand: std.Random,
    ) !void {
        var spawn = try Spawn.new(rand);

        while (!self.isPosAvailable(spawn.pos)) {
            spawn = try Spawn.new(rand);
        }

        try self.snakes.append(
            alloc,
            try core.Snake.initAt(alloc, spawn.pos, spawn.direction),
        );
    }

    pub fn encodeDeltas(self: *const TronGame, buf: []u8) []u8 {
        const needed = self.deltas.items.len * Delta.encoded_len;
        std.debug.assert(buf.len >= needed);

        var offset: usize = 0;
        for (self.deltas.items) |delta| {
            const bytes = delta.encode();
            @memcpy(buf[offset..][0..bytes.len], &bytes);
            offset += bytes.len;
        }

        return buf[0..needed];
    }

    // Snapshot each live snake's next head cell; dead snakes are null.
    pub fn nextPositions(self: *TronGame, alloc: std.mem.Allocator) !void {
        const s = self.snakes.slice();
        const dead = s.items(.is_dead);
        const dir = s.items(.direction);
        const body = s.items(.body);

        var delta: Delta = .init;
        for (dead, 0..) |is_dead, i| {
            if (is_dead) {
                try self.deltas.append(alloc, delta);
                continue;
            }
            const next_pos = core.nextPos(dir[i], body[i].items[0]);
            delta.nextPos = next_pos;
            try self.deltas.append(alloc, delta);
        }
    }

    // Two live heads aiming at the same cell: the one with fewer kills dies
    // (ties: the higher index dies), the other is credited the kill.
    pub fn checkH2HCollision(self: *TronGame) void {
        const positions = self.deltas.items;
        const s = self.snakes.slice();
        const dead = s.items(.is_dead);
        const kills = s.items(.kills);

        for (positions, 0..) |maybe_a, i| {
            if (i == self.snakes.len - 1) break;
            const a = maybe_a.nextPos orelse continue;
            var j = i + 1;
            while (j < self.snakes.len) : (j += 1) {
                const b = positions[j].nextPos orelse continue;
                if (!std.meta.eql(a, b)) continue;

                if (kills[i] >= kills[j]) {
                    positions[j].death = .{
                        .died = @intCast(j),
                        .killer = @intCast(i),
                    };
                    dead[j] = true;
                } else {
                    positions[i].death = .{
                        .died = @intCast(i),
                        .killer = @intCast(j),
                    };
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

        for (0..self.snakes.len) |i| {
            if (dead[i]) continue;
            const target = self.deltas.items[i].nextPos orelse continue;
            for (0..self.snakes.len) |j| {
                if (i == j) continue;
                if (core.bodyContains(body[j].items, target)) {
                    self.deltas.items[i].death = .{
                        .died = @intCast(i),
                        .killer = @intCast(j),
                    };
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

        for (0..self.snakes.len) |i| {
            if (dead[i]) continue;
            const target = self.deltas.items[i].nextPos orelse {
                self.deltas.items[i].death = .{
                    .died = @intCast(i),
                    .killer = null,
                };
                dead[i] = true;
                continue;
            };
            if (core.bodyContains(body[i].items, target)) {
                self.deltas.items[i].death = .{
                    .died = @intCast(i),
                    .killer = null,
                };
                dead[i] = true;
            }
        }
    }

    pub fn applyDeaths(self: *TronGame) void {
        const s = self.snakes.slice();
        const dead = s.items(.is_dead);
        const kills = s.items(.kills);
        const body = s.items(.body);

        for (self.deltas.items) |maybe_death| {
            const death = maybe_death.death orelse continue;
            dead[death.died] = true; // update snake status
            body[death.died].clearRetainingCapacity(); // snake body struct is still allocated just len 0
            if (death.killer) |killer| kills[killer] += 1; // grant kill to killer
        }
    }

    pub fn advanceSnakes(self: *TronGame, alloc: std.mem.Allocator) !void {
        const s = self.snakes.slice();
        const dead = s.items(.is_dead);
        const body = s.items(.body);

        var dead_count: u8 = 0;
        for (0..self.snakes.len) |i| {
            if (dead[i]) {
                dead_count += 1;
                continue;
            }

            if (self.deltas.items[i].nextPos) |target| {
                try body[i].insert(alloc, 0, target);
            }
        }
        if (dead_count == self.snakes.len - 1 or dead_count == self.snakes.len) self.state = .over;
    }

    pub fn resetDelta(self: *TronGame, alloc: std.mem.Allocator) !void {
        self.deltas.clearRetainingCapacity();
        try self.nextPositions(alloc);
    }

    pub fn tick(self: *TronGame, alloc: std.mem.Allocator) !void {
        try self.resetDelta(alloc);
        self.checkBodyCollision();
        self.checkH2HCollision();
        self.checkSelfCollision();
        self.applyDeaths();
        try self.advanceSnakes(alloc);
    }
};

test "spawned snakes do not overlap" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = TronGame.init;
    defer game.deinit(talloc);

    try game.spawnSnake(talloc, rand);
    try game.spawnSnake(talloc, rand);
    try game.spawnSnake(talloc, rand);

    const bodies = game.snakes.items(.body);
    try t.expect(!core.bodyContains(bodies[0].items, bodies[1].items[0]));
    try t.expect(!core.bodyContains(bodies[1].items, bodies[2].items[0]));
    try t.expect(!core.bodyContains(bodies[0].items, bodies[2].items[0]));
}

test "isPosAvailable" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = TronGame.init;
    defer game.deinit(talloc);
    const spawn = try Spawn.new(rand);

    try t.expect(game.isPosAvailable(spawn.pos));

    for (0..10) |_| try game.spawnSnake(talloc, rand);

    try t.expect(!game.isPosAvailable(game.snakes.get(0).body.items[0]));
}

test "wall collision test" {
    var game = TronGame.init;
    defer game.deinit(talloc);

    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 0, .y = 0 }, .down),
    );
    game.snakes.items(.direction)[0] = .left; // next() is null off the left edge
    try game.resetDelta(talloc);
    game.checkSelfCollision();

    const death_res = game.deltas.items[0].death;

    try t.expectEqual(0, death_res.?.died);
}

test "self collision test" {
    var game = TronGame.init;
    defer game.deinit(talloc);

    // A 2x2 loop: head at {10,10} moving right lands on the tail at {11,10}.
    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 0, .y = 0 }, .right),
    );
    const body = &game.snakes.items(.body)[0];
    body.clearRetainingCapacity();
    try body.append(talloc, .{ .x = 10, .y = 10 }); // head
    try body.append(talloc, .{ .x = 10, .y = 11 });
    try body.append(talloc, .{ .x = 11, .y = 11 });
    try body.append(talloc, .{ .x = 11, .y = 10 }); // tail (the cell we hit)
    game.snakes.items(.direction)[0] = .right;
    try game.resetDelta(talloc);
    game.checkSelfCollision();

    const death_res = game.deltas.items[0].death;

    try t.expectEqual(0, death_res.?.died);
}

test "tick test" {
    var game = TronGame.init;
    defer game.deinit(talloc);

    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 0, .y = 0 }, .down),
    );
    try game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 10, .y = 10 }, .down),
    );

    try game.tick(talloc);

    try t.expectEqual(2, game.snakes.items(.body)[0].items.len);
    try t.expectEqual(2, game.snakes.items(.body)[1].items.len);
}

test "tick mutates snakes is dead test" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = TronGame.init;
    defer game.deinit(talloc);

    try game.spawnSnake(talloc, rand);
    game.snakes.items(.body)[0].items[0] = .{ .x = 0, .y = 16 };
    game.snakes.items(.direction)[0] = .left; // next() is null off the left edge
    try game.tick(talloc);

    try t.expect(game.snakes.items(.is_dead)[0]);
}

test "when snake dies body is cleared test" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = TronGame.init;
    defer game.deinit(talloc);

    try game.spawnSnake(talloc, rand);
    game.snakes.items(.body)[0].items[0] = .{ .x = 0, .y = 16 };
    game.snakes.items(.direction)[0] = .left; // next() is null off the left edge
    try game.tick(talloc);
    try game.tick(talloc);

    try t.expectEqual(0, game.snakes.items(.body)[0].items.len);
    try t.expect(game.snakes.items(.is_dead)[0]);
}

test "advanceSnake sets game state to dead with one alive snake" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = TronGame.init;
    defer game.deinit(talloc);

    try game.spawnSnake(talloc, rand);
    try game.spawnSnake(talloc, rand);
    while (game.state != .over) {
        try game.tick(talloc);
    }

    try t.expectEqual(GameState.over, game.state);

    const s = game.snakes.slice();
    const dead = s.items(.is_dead);
    var dead_count: u4 = 0;
    for (dead) |is_dead| {
        if (is_dead) dead_count += 1;
    }

    try t.expectEqual(1, dead_count);
}

test "collision with other snakes body" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = TronGame.init;
    defer game.deinit(talloc);

    try game.spawnSnake(talloc, rand);
    try game.spawnSnake(talloc, rand);
    const bodies = game.snakes.items(.body);
    const dirs = game.snakes.items(.direction);

    bodies[0].items[0] = .{ .x = 0, .y = 0 };
    try bodies[0].append(talloc, .{ .x = 0, .y = 1 });
    try bodies[0].append(talloc, .{ .x = 0, .y = 2 });
    dirs[0] = .right;

    bodies[1].items[0] = .{ .x = 1, .y = 1 };
    try bodies[1].append(talloc, .{ .x = 2, .y = 1 });
    try bodies[1].append(talloc, .{ .x = 3, .y = 1 });
    dirs[1] = .left;

    try game.tick(talloc);

    try t.expect(game.snakes.items(.is_dead)[1]);
    try t.expectEqual(0, bodies[1].items.len);
}

test "collision with other snakes body adds to kill count" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = TronGame.init;
    defer game.deinit(talloc);

    try game.spawnSnake(talloc, rand);
    try game.spawnSnake(talloc, rand);
    const bodies = game.snakes.items(.body);
    const dirs = game.snakes.items(.direction);

    bodies[0].items[0] = .{ .x = 0, .y = 0 };
    try bodies[0].append(talloc, .{ .x = 0, .y = 1 });
    try bodies[0].append(talloc, .{ .x = 0, .y = 2 });
    dirs[0] = .right;

    bodies[1].items[0] = .{ .x = 1, .y = 1 };
    try bodies[1].append(talloc, .{ .x = 2, .y = 1 });
    try bodies[1].append(talloc, .{ .x = 3, .y = 1 });
    dirs[1] = .left;

    try game.tick(talloc);

    try t.expectEqual(1, game.snakes.items(.kills)[0]);
}

test "encodeDeltas packs every snake's delta into one flat byte buffer" {
    var game = TronGame.init;
    defer game.deinit(talloc);

    try game.deltas.append(talloc, .{ .death = .{ .died = 0, .killer = 1 }, .nextPos = .{ .x = 1, .y = 2 } });
    try game.deltas.append(
        talloc,
        .{ .death = null, .nextPos = .{ .x = 5, .y = 6 } },
    );
    try game.deltas.append(
        talloc,
        .{ .death = .{ .died = 2, .killer = null }, .nextPos = null },
    );
    try game.deltas.append(talloc, .{ .death = null, .nextPos = null });
    try game.deltas.append(
        talloc,
        .{
            .death = .{ .died = 4, .killer = 0 },
            .nextPos = .{ .x = 10, .y = 20 },
        },
    );

    var buf: [20]u8 = undefined;
    _ = game.encodeDeltas(&buf);
    const expected = [20]u8{
        0x07, 1, 1,  2,
        0x04, 0, 5,  6,
        0x01, 0, 0,  0,
        0x00, 0, 0,  0,
        0x07, 0, 10, 20,
    };

    try t.expectEqual(expected, buf);
}

test "collision h2h test" {
    var game = TronGame.init;
    defer game.deinit(talloc);
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    try game.spawnSnake(talloc, rand);
    try game.spawnSnake(talloc, rand);

    const bodies = game.snakes.items(.body);
    const dirs = game.snakes.items(.direction);
    const kills = game.snakes.items(.kills);

    kills[1] = 1;

    bodies[0].items[0] = .{ .x = 0, .y = 0 };
    dirs[0] = .right;

    bodies[1].items[0] = .{ .x = 2, .y = 0 };
    dirs[1] = .left;

    try game.tick(talloc);

    try t.expect(game.snakes.items(.is_dead)[0]);
    try t.expectEqual(2, game.snakes.items(.kills)[1]);
}

pub const Delta = struct {
    death: ?TronGame.DeathResult,
    nextPos: ?core.Position,

    const init: Delta = .{ .death = null, .nextPos = null };

    pub const encoded_len: usize = 4;
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
        const delta = Delta{
            .death = .{ .died = 1, .killer = 4 },
            .nextPos = .{ .x = 3, .y = 5 },
        };
        const expected: [4]u8 = .{ 0x07, 4, 3, 5 };

        const encoded_delta = delta.encode();
        try t.expectEqual(expected, encoded_delta);
    }
};

pub const ClassicGame = struct {
    score: u8,
    state: GameState,
    snake: core.Snake,
    food: Food,

    pub fn init(alloc: std.mem.Allocator, rand: std.Random) !ClassicGame {
        const snake = try core.Snake.init(alloc);
        const state: GameState = .running;
        const food = Food.new(rand);

        return .{
            .score = 0,
            .snake = snake,
            .food = food,
            .state = state,
        };
    }

    pub fn deinit(self: *ClassicGame, alloc: std.mem.Allocator) void {
        self.snake.deinit(alloc);
    }

    pub fn spawnFood(self: *ClassicGame, rand: std.Random) ?Food {
        // check if board is full with snakes body
        if (self.snake.len() == core.GRID_HEIGHT * core.GRID_WIDTH) return null;
        var new_food = Food.new(rand);
        // generate new food pos thats not the snakes body
        while (core.bodyContains(self.snake.body.items, new_food.pos)) {
            new_food = Food.new(rand);
        }

        return new_food;
    }

    pub fn tick(
        self: *ClassicGame,
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
};

test "classic snake movement" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = try ClassicGame.init(talloc, rand);
    defer game.deinit(talloc);

    const len_before = game.snake.len();
    try game.tick(talloc, rand);

    try t.expectEqual(len_before, game.snake.len());
}

test "classic snake growth by eating" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try ClassicGame.init(talloc, rand);
    defer game.deinit(talloc);
    const center = core.gridCenter();

    game.food.pos.x = center.x + 1;
    game.food.pos.y = center.y;

    try game.tick(talloc, rand);

    try t.expectEqual(1, game.score);
    try t.expectEqual(2, game.snake.len());
}

test "food is respawning after being eaten" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try ClassicGame.init(talloc, rand);
    defer game.deinit(talloc);
    const center = core.gridCenter();

    game.food.pos.x = center.x + 1;
    game.food.pos.y = center.y;

    const food_before = game.food;

    try game.tick(talloc, rand);

    try t.expect(!std.meta.eql(food_before.pos, game.food.pos));
}

test "classic game tick mutates game state if snakes dies" {
    const alloc = t.allocator;
    const io = t.io;
    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try ClassicGame.init(alloc, rand);
    defer game.deinit(alloc);

    game.snake.body.items[0] = .{ .x = 0, .y = 16 };
    game.snake.direction = .left; // next() is null off the left edge
    try game.tick(alloc, rand);

    try t.expectEqual(GameState.over, game.state);
}

test "classic game spawns food free from snakes body" {
    const alloc = t.allocator;
    const io = t.io;
    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try ClassicGame.init(alloc, rand);
    defer game.deinit(alloc);
    game.snake.body.items[0] = core.Position{
        .x = 0,
        .y = core.GRID_WIDTH - 1,
    };
    game.snake.direction = .left;

    for (0..core.GRID_WIDTH / 3) |x| {
        for (1..core.GRID_HEIGHT - 1) |y| {
            const pos: core.Position = .{ .x = @intCast(x), .y = @intCast(y) };
            try game.snake.body.append(alloc, pos);
        }
    }
    const new_food = game.spawnFood(rand).?;

    try t.expect(!core.bodyContains(game.snake.body.items, new_food.pos));
}
