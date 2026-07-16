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
            .pos = .{ .x = rand.intRangeLessThan(u8, 0, core.GRID_WIDTH - 1), .y = rand.intRangeLessThan(u8, 0, core.GRID_HEIGHT - 1) },
        };
    }
};

pub const TronGame = struct {
    state: GameState,
    snakes: std.MultiArrayList(core.Snake),
    delta: [n_snakes]Delta,

    pub const n_snakes: u8 = 5;
    const DeathResult = struct { died: u8, killer: ?u8 };

    pub fn init(gpa: std.mem.Allocator) !TronGame {
        const direction_a, const pos_a = core.gridCorner(.down);
        const direction_b, const pos_b = core.gridCorner(.up);
        const direction_c, const pos_c = core.gridCorner(.left);
        const direction_d, const pos_d = core.gridCorner(.right);
        const pos_e = core.gridCenter();
        const direction_e: core.Snake.Direction = .left;

        var snakes: std.MultiArrayList(core.Snake) = .empty;
        try snakes.append(gpa, try core.Snake.initAt(gpa, pos_a, direction_a));
        try snakes.append(gpa, try core.Snake.initAt(gpa, pos_b, direction_b));
        try snakes.append(gpa, try core.Snake.initAt(gpa, pos_c, direction_c));
        try snakes.append(gpa, try core.Snake.initAt(gpa, pos_d, direction_d));
        try snakes.append(gpa, try core.Snake.initAt(gpa, pos_e, direction_e));

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
            self.delta[i].nextPos = if (dead[i]) null else core.nextPos(dir[i], body[i].items[0]);
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
                if (core.bodyContains(body[j].items, target)) {
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
            if (core.bodyContains(body[i].items, target)) {
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

test "step into the wall annotates snake is dead and hit a wall" {
    var game = try TronGame.init(talloc);
    defer game.deinit(talloc);

    game.snakes.items(.direction)[0] = .left; // next() is null off the left edge
    game.resetDelta();
    game.checkSelfCollision();

    const death_res = game.delta[0].death;

    try t.expectEqual(0, death_res.?.died);
}

test "step into own body ends the game" {
    var game = try TronGame.init(talloc);
    defer game.deinit(talloc);

    // A 2x2 loop: head at {10,10} moving right lands on the tail at {11,10}.
    const body = &game.snakes.items(.body)[0];
    body.clearRetainingCapacity();
    try body.append(talloc, .{ .x = 10, .y = 10 }); // head
    try body.append(talloc, .{ .x = 10, .y = 11 });
    try body.append(talloc, .{ .x = 11, .y = 11 });
    try body.append(talloc, .{ .x = 11, .y = 10 }); // tail (the cell we hit)
    game.snakes.items(.direction)[0] = .right;
    game.resetDelta();
    game.checkSelfCollision();

    const death_res = game.delta[0].death;

    try t.expectEqual(0, death_res.?.died);
}

test "simple game tick test" {
    var game = try TronGame.init(talloc);
    defer game.deinit(talloc);

    try game.tick(talloc);

    try t.expectEqual(2, game.snakes.items(.body)[0].items.len);
    try t.expectEqual(2, game.snakes.items(.body)[1].items.len);
}

test "game tick annotate snake is dead" {
    var game = try TronGame.init(talloc);
    defer game.deinit(talloc);

    game.snakes.items(.body)[0].items[0] = .{ .x = 0, .y = 16 };
    game.snakes.items(.direction)[0] = .left; // next() is null off the left edge
    try game.tick(talloc);

    try t.expect(game.snakes.items(.is_dead)[0]);
}

test "game tick snakes dies check if dead snake body is gone" {
    var game = try TronGame.init(talloc);
    defer game.deinit(talloc);

    game.snakes.items(.body)[0].items[0] = .{ .x = 0, .y = 16 };
    game.snakes.items(.direction)[0] = .left; // next() is null off the left edge
    try game.tick(talloc);
    try game.tick(talloc);

    try t.expectEqual(0, game.snakes.items(.body)[0].items.len);
    try t.expect(!game.snakes.items(.is_dead)[1]);
}

test "advanceSnake sets game state to dead with one alive snake" {
    var game = try TronGame.init(talloc);
    defer game.deinit(talloc);

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

    try t.expectEqual(5, dead_count);
}

test "collision with other snakes body" {
    var game = try TronGame.init(talloc);
    defer game.deinit(talloc);

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
    var game = try TronGame.init(talloc);
    defer game.deinit(talloc);

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
    var game = try TronGame.init(talloc);
    defer game.deinit(talloc);

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

    try t.expectEqual(expected, encoded);
}

test "collision h2h test" {
    var game = try TronGame.init(talloc);
    defer game.deinit(talloc);

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
            .death = .{
                .died = 1,
                .killer = 4,
            },
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

        return .{ .score = 0, .snake = snake, .food = food, .state = state };
    }

    pub fn deinit(self: *ClassicGame, gpa: std.mem.Allocator) void {
        self.snake.deinit(gpa);
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

    pub fn tick(self: *ClassicGame, alloc: std.mem.Allocator, rand: std.Random) !void {
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
    const gpa = t.allocator;
    const io = t.io;
    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try ClassicGame.init(gpa, rand);
    defer game.deinit(gpa);

    game.snake.body.items[0] = .{ .x = 0, .y = 16 };
    game.snake.direction = .left; // next() is null off the left edge
    try game.tick(gpa, rand);

    try t.expectEqual(GameState.over, game.state);
}

test "classic game spawns food free from snakes body" {
    const gpa = t.allocator;
    const io = t.io;
    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var game = try ClassicGame.init(gpa, rand);
    defer game.deinit(gpa);
    game.snake.body.items[0] = core.Position{
        .x = 0,
        .y = core.GRID_WIDTH - 1,
    };
    game.snake.direction = .left;

    for (0..core.GRID_WIDTH / 3) |x| {
        for (1..core.GRID_HEIGHT - 1) |y| {
            const pos = core.Position{ .x = @intCast(x), .y = @intCast(y) };
            try game.snake.body.append(gpa, pos);
        }
    }
    const new_food = game.spawnFood(rand).?;

    try t.expect(!core.bodyContains(game.snake.body.items, new_food.pos));
}
