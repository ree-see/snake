const std = @import("std");
const core = @import("core");
const games = @import("games.zig");

const Tron = @This();
/// Server-authoritative, trail-growing multiplayer game state.
state: games.GameState,
snakes: std.MultiArrayList(core.Snake),
deltas: std.ArrayList(Delta),
frame_seq: u32 = 0,

/// Initial head position for one snake in a client match snapshot.
pub const InitialSnapshot = struct {
    idx: usize,
    x: u16,
    y: u16,

    /// Allocates snapshots for every pre-tick Tron snake.
    ///
    /// The caller owns and must free the returned slice with `alloc`.
    pub fn fromTron(
        alloc: std.mem.Allocator,
        game: *const Tron,
    ) ![]InitialSnapshot {
        const s = game.snakes.slice();
        const bodies = s.items(.body);

        var buf: std.ArrayList(InitialSnapshot) = .empty;
        errdefer buf.deinit(alloc);

        for (bodies, 0..) |body, i| {
            std.debug.assert(body.items.len == 1);

            const snake: InitialSnapshot = .{
                .idx = i,
                .x = body.items[0].x,
                .y = body.items[0].y,
            };
            try buf.append(alloc, snake);
        }

        return try buf.toOwnedSlice(alloc);
    }
};

pub const SnakeSnapshot = struct {
    idx: usize,
    is_dead: bool,
    body: []const core.Position,

    pub fn fromTron(
        alloc: std.mem.Allocator,
        game: *const Tron,
    ) ![]SnakeSnapshot {
        const s = game.snakes.slice();
        const bodies = s.items(.body);
        const is_dead = s.items(.is_dead);

        var buf: std.ArrayList(SnakeSnapshot) = .empty;
        errdefer buf.deinit(alloc);

        for (bodies, 0..) |body, i| {
            // var body_buf: [body.items.len]core.Position = undefined;
            const snake: SnakeSnapshot = .{
                .idx = i,
                .is_dead = is_dead[i],
                .body = body.items,
            };
            try buf.append(alloc, snake);
        }

        return buf.toOwnedSlice(alloc);
    }
};

/// A randomized initial position and direction for a Tron snake.
pub const Spawn = struct {
    pos: core.Position,
    direction: core.Snake.Direction,

    /// Chooses a spawn within the board margin. Occupancy is checked by the caller.
    pub fn new(rand: std.Random) !Spawn {
        const x = rand.intRangeLessThan(u16, 0, core.GRID_WIDTH - 5);
        const y = rand.intRangeLessThan(u16, 0, core.GRID_HEIGHT - 5);
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

const DeathResult = struct { died: u8, killer: ?u8 };

/// Per-snake outcome for one Tron tick.
pub const Delta = struct {
    death: ?DeathResult,
    nextPos: ?core.Position,

    pub const init: Delta = .{ .death = null, .nextPos = null };

    /// Fixed byte width of the binary delta wire format.
    pub const encoded_len: usize = 6;
    const Header = packed struct {
        has_death: bool,
        has_killer: bool,
        has_pos: bool,
        _: u5 = 0,
    };

    /// Encodes flags, killer index, and optional next-head position into encoded_len bytes.
    ///
    /// The dead snake index is implied by the delta's position in the frame.
    pub fn encode(d: Delta) [encoded_len]u8 {
        var payload: [encoded_len]u8 = undefined;
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

        for (0..6) |i| {
            switch (i) {
                0 => payload[i] = @bitCast(header),
                1 => payload[i] = if (header.has_killer) d.death.?.killer.? else 0,
                2 => payload[i] = if (header.has_pos) @truncate(d.nextPos.?.x) else 0,
                3 => payload[i] = if (header.has_pos) @truncate(d.nextPos.?.x >> 8) else 0,
                4 => payload[i] = if (header.has_pos) @truncate(d.nextPos.?.y) else 0,
                5 => payload[i] = if (header.has_pos) @truncate(d.nextPos.?.y >> 8) else 0,
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
        const expected: [6]u8 = .{ 0x07, 4, 3, 0, 5, 0 };

        const encoded_delta = delta.encode();
        try t.expectEqual(expected, encoded_delta);
    }
};
/// Empty lobby state ready to receive spawned snakes.
pub const init: Tron = .{
    .state = .lobby,
    .snakes = .empty,
    .deltas = .empty,
};

/// Releases every snake body, SoA column, and accumulated delta.
pub fn deinit(self: *Tron, alloc: std.mem.Allocator) void {
    // Each body owns its own heap allocation — free them before the columns.
    for (self.snakes.items(.body)) |*body| body.deinit(alloc);
    self.snakes.deinit(alloc);
    self.deltas.deinit(alloc);
}

/// Reports whether no current snake body occupies `pos`.
pub fn isPosAvailable(self: *const Tron, pos: core.Position) bool {
    const s = self.snakes.slice();
    const bodies = s.items(.body);
    for (bodies) |snakes_body| {
        if (core.bodyContains(snakes_body.items, pos)) return false;
    }
    return true;
}

/// Appends one randomly placed snake whose initial cell is unoccupied.
pub fn spawnSnake(
    self: *Tron,
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

/// Encodes the current per-snake deltas into caller-provided storage.
///
/// `buf` must hold `4 + deltas.len * Delta.encoded_len` bytes.
pub fn encodeDeltas(self: *const Tron, buf: []u8) []u8 {
    const needed = 4 + self.deltas.items.len * Delta.encoded_len;
    std.debug.assert(buf.len >= needed);

    var offset: usize = 4;
    std.mem.writeInt(u32, buf[0..4], self.frame_seq, .big);
    for (self.deltas.items) |delta| {
        const bytes = delta.encode();
        @memcpy(buf[offset .. offset + 6][0..bytes.len], &bytes);
        offset += bytes.len;
    }

    return buf[0..needed];
}

/// Snapshots each live snake's next head cell; dead snakes produce null.
pub fn nextPositions(self: *Tron, alloc: std.mem.Allocator) !void {
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

/// Resolves equal-target head collisions using kills, then lower index, as ties.
pub fn checkH2HCollision(self: *Tron) void {
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

/// Marks heads that enter another snake's body dead and credits the owner.
pub fn checkBodyCollision(self: *Tron) void {
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

/// Marks wall and self collisions dead without awarding a kill.
pub fn checkSelfCollision(self: *Tron) void {
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

/// Applies recorded deaths by clearing bodies and incrementing credited kills.
pub fn applyDeaths(self: *Tron) void {
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

/// Prepends each surviving next head and ends the game with zero or one survivors.
pub fn advanceSnakes(self: *Tron, alloc: std.mem.Allocator) !void {
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

/// Clears the prior frame's deltas and captures positions for the next frame.
pub fn resetDelta(self: *Tron, alloc: std.mem.Allocator) !void {
    self.deltas.clearRetainingCapacity();
    try self.nextPositions(alloc);
}

/// Advances one deterministic Tron frame through collision and movement phases.
pub fn tick(self: *Tron, alloc: std.mem.Allocator) !void {
    try self.resetDelta(alloc);
    self.checkBodyCollision();
    self.checkH2HCollision();
    self.checkSelfCollision();
    self.applyDeaths();
    try self.advanceSnakes(alloc);
    self.frame_seq += 1;
}

const t = std.testing;
const tio = t.io;
const talloc = t.allocator;

test "spawned snakes do not overlap" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = Tron.init;
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
    var game = Tron.init;
    defer game.deinit(talloc);
    const spawn = try games.Spawn.new(rand);

    try t.expect(game.isPosAvailable(spawn.pos));

    for (0..10) |_| try game.spawnSnake(talloc, rand);

    try t.expect(!game.isPosAvailable(game.snakes.get(0).body.items[0]));
}

test "wall collision test" {
    var game = Tron.init;
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
    var game = Tron.init;
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
    var game = Tron.init;
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
    var game = Tron.init;
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
    var game = Tron.init;
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
    var game = Tron.init;
    defer game.deinit(talloc);

    try game.spawnSnake(talloc, rand);
    try game.spawnSnake(talloc, rand);
    while (game.state != .over) {
        try game.tick(talloc);
    }

    try t.expectEqual(games.GameState.over, game.state);

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
    var game = Tron.init;
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
    var game = Tron.init;
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
    var game = Tron.init;
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

    game.frame_seq = 1;
    var buf: [34]u8 = undefined;
    _ = game.encodeDeltas(&buf);
    const expected = [34]u8{
        0,    0, 0,    1,
        0x07, 1, 1,    0,
        2,    0, 0x04, 0,
        5,    0, 6,    0,
        0x01, 0, 0,    0,
        0,    0, 0x00, 0,
        0,    0, 0,    0,
        0x07, 0, 10,   0,
        20,   0,
    };

    try t.expectEqual(expected, buf);
}

test "collision h2h test" {
    var game = Tron.init;
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
