const std = @import("std");
const core = @import("core");

const Br = @This();

const assert = std.debug.assert;
const t = std.testing;
const talloc = t.allocator;
const tio = t.io;

const max_players = 100;
const max_snakes_len = 3000;
const max_width = 1000;
const max_height = 1000;

/// Fixed player-id slots. `null` means the player has not spawned this match.
players: [max_players]?BrPlayer,
/// Dense arena ownership index; `0` is empty and `1..100` are player IDs.
owners: Occupancy,
/// Number of spawned players, equal to the number of non-null player slots.
player_count: u8 = 0,

/// Empty BR arena with no players and no claimed cells.
pub const init: Br = .{
    .players = [_]?BrPlayer{null} ** max_players,
    .owners = .init,
};

/// Per-player BR state stored in the fixed player-id slot.
const BrPlayer = struct {
    id: PlayerId,
    direction: core.Snake.Direction,
    is_dead: bool,
    kills: u8 = 0,
    body: Ring,

    /// Empty player storage used only while constructing a live player.
    pub const init: BrPlayer = .{
        .id = undefined,
        .direction = undefined,
        .is_dead = false,
        .body = .empty,
    };

    pub fn die(self: *BrPlayer) void {
        self.is_dead = true;
        self.body.reset();
    }
};

/// Valid external player identity in the inclusive range `1..max_players`.
const PlayerId = struct {
    id: u8,

    /// Rejects zero and IDs that exceed the fixed player capacity.
    pub fn init(with_id: u8) !PlayerId {
        if (with_id == 0 or with_id > max_players) return error.NotValidId;
        return .{ .id = with_id };
    }
};

/// Fixed row-major arena index for O(1) cell ownership checks.
const Occupancy = struct {
    // `0` is empty; `1..100` are raw PlayerId values.
    cells: [max_width * max_height]u8,

    /// Clears every arena cell.
    pub const init: Occupancy = .{ .cells = @splat(0) };

    /// Maps an in-bounds position to its row-major index: `y * width + x`.
    /// Row `y = 0` occupies indices `0..999`; row `y = 999` occupies `999_000..999_999`.
    pub fn posToIdx(pos: core.Position) !usize {
        if (pos.x >= max_width or pos.y >= max_height or pos.x < 0 or pos.y < 0) return error.OutOfBounds;

        return @as(usize, pos.y) * max_width + pos.x;
    }

    /// Reports whether an in-bounds cell has no owning player.
    pub fn isEmpty(self: *const Occupancy, pos: core.Position) !bool {
        const idx = posToIdx(pos) catch |e| return e;

        return self.cells[idx] == 0;
    }

    /// Returns the owning player ID, or null for an empty in-bounds cell.
    pub fn ownerAt(self: *const Occupancy, pos: core.Position) !?u8 {
        const idx = posToIdx(pos) catch |e| return e;
        if (try self.isEmpty(pos)) return null;
        return self.cells[idx];
    }

    /// Claims an empty in-bounds cell for `player_id`.
    /// Returns `CellOccupied` when another player already owns the cell.
    pub fn claim(
        self: *Occupancy,
        pos: core.Position,
        player_id: PlayerId,
    ) !void {
        const idx = posToIdx(pos) catch |e| return e;
        if (self.cells[idx] != 0) return error.CellOccupied;
        self.cells[idx] = player_id.id;
    }

    /// Clears an in-bounds cell only when it is owned by `expected_owner`.
    /// Returns `WrongOwner` to expose an attempted grid/ring desynchronization.
    pub fn clear(
        self: *Occupancy,
        pos: core.Position,
        expected_owner: PlayerId,
    ) !void {
        const idx = posToIdx(pos) catch |e| return e;
        if (self.cells[idx] != expected_owner.id) return error.WrongOwner;
        self.cells[idx] = 0;
    }
};

/// Fixed-capacity, tail-to-head trail storage for one BR player.
const Ring = struct {
    body: [max_snakes_len]core.Position,
    count: u16 = 0, // num of live positions
    start: u16 = 0, // tail idx in the body

    /// Empty ring. Entries outside the live `count` are intentionally undefined.
    pub const empty: Ring = .{ .body = undefined };

    /// Reports whether the ring has no live trail cells.
    pub fn isEmpty(self: *const Ring) bool {
        return self.count == 0;
    }

    /// Appends a new head cell without moving the tail.
    /// Returns `BodyFull` rather than overwriting a live tail cell.
    pub fn pushHead(self: *Ring, pos: core.Position) !void {
        if (self.count == max_snakes_len) return error.BodyFull;
        self.body[(self.start + self.count) % 3000] = pos;
        self.count += 1;
    }

    /// Removes the oldest tail cell and advances the wrapped tail index.
    pub fn popTail(self: *Ring) !void {
        if (self.isEmpty() or self.tail() == null) return error.NoBody;

        self.start = @intCast((self.start + 1) % self.body.len);
        self.count -= 1;
    }

    /// Returns the oldest live cell, or null for an empty ring.
    pub fn tail(self: *const Ring) ?core.Position {
        if (self.isEmpty()) return null;
        return self.body[self.start];
    }

    /// Returns the newest live cell, or null for an empty ring.
    pub fn head(self: *const Ring) ?core.Position {
        if (self.isEmpty()) return null;
        return self.body[(self.count + self.start - 1) % self.body.len];
    }

    pub fn reset(self: *Ring) void {
        self.* = .empty;
    }

    const Iterator = struct {
        ring: *const Ring,
        returned: u16 = 0,

        pub fn next(it: *Iterator) ?core.Position {
            // return null if no positions, a guard to not read undefined memory
            if (it.returned == it.ring.count or it.ring.isEmpty()) return null;
            defer it.returned += 1;
            return it.ring.body[(it.ring.start + it.returned) % it.ring.body.len];
        }
    };

    /// Returns an iterator to iterate through the defined ring body positions
    pub fn iter(self: *const Ring) Ring.Iterator {
        return .{ .ring = self };
    }
};

/// Randomly chooses an unoccupied spawn cell, then initializes its player slot and one-cell trail.
/// Returns `FullGame` when all player slots are registered and rejects duplicate player IDs.
pub fn spawnPlayer(self: *Br, p_id: PlayerId, rand: std.Random) !void {
    if (self.player_count == 100) return error.FullGame;
    if (self.players[p_id.id - 1] != null) return error.PlayerIdAlreadyExists;

    var pos: core.Position = .{
        .x = rand.intRangeLessThan(u16, 0, max_width - 10),
        .y = rand.intRangeLessThan(u16, 0, max_height - 10),
    };
    while (!try self.owners.isEmpty(pos)) {
        pos = .{
            .x = rand.intRangeLessThan(u16, 0, max_width - 10),
            .y = rand.intRangeLessThan(u16, 0, max_height - 10),
        };
    }
    const dir = try core.dirFromKeyPress(rand.intRangeLessThan(u8, 105, 109));
    try self.owners.claim(pos, p_id);
    var br_player: BrPlayer = .{
        .id = p_id,
        .direction = dir,
        .is_dead = false,
        .body = .empty,
    };

    try br_player.body.pushHead(pos);
    self.players[p_id.id - 1] = br_player;
    self.player_count += 1;
}

/// Initializes a player at an exact cell for deterministic BR tests.
/// Production random spawning uses `spawnPlayer`.
pub fn spawnPlayerAt(
    self: *Br,
    p_id: PlayerId,
    pos: core.Position,
    rand: std.Random,
) !void {
    if (self.player_count == 100) return error.FullGame;
    if (self.players[p_id.id - 1] != null) return error.PlayerIdAlreadyExists;
    const dir = try core.dirFromKeyPress(rand.intRangeLessThan(u8, 105, 109));
    try self.owners.claim(pos, p_id);
    var br_player: BrPlayer = .{
        .id = p_id,
        .direction = dir,
        .is_dead = false,
        .body = .empty,
    };

    try br_player.body.pushHead(pos);
    self.players[p_id.id - 1] = br_player;
    self.player_count += 1;
}

fn calcNextPos(p: BrPlayer) !?core.Position {
    const p_curr_pos = p.body.head() orelse return error.UhOh;
    const p_curr_dir = p.direction;
    return switch (p_curr_dir) {
        .down => if (p_curr_pos.y != max_height - 1) .{ .x = p_curr_pos.x, .y = p_curr_pos.y + 1 } else null,
        .up => if (p_curr_pos.y != 0) .{
            .x = p_curr_pos.x,
            .y = p_curr_pos.y - 1,
        } else null,
        .left => if (p_curr_pos.x != 0) .{
            .x = p_curr_pos.x - 1,
            .y = p_curr_pos.y,
        } else null,
        .right => if (p_curr_pos.x != max_width - 1) .{ .x = p_curr_pos.x + 1, .y = p_curr_pos.y } else null,
    };
}

pub fn tick(self: *Br) !void {
    // look at every players next pos
    var next_pos: [max_players]?core.Position = @splat(null);
    assert(self.player_count != 0);
    for (self.players, 0..) |maybe_p, i| {
        const p = maybe_p orelse {
            next_pos[i] = null;
            continue;
        };
        // dead players dont have next positions
        if (p.is_dead) {
            next_pos[i] = null;
            continue;
        }
        const pid = p.id;
        const p_next_pos = try calcNextPos(p) orelse {
            next_pos[i] = null;
            continue;
        };
        // decide on the result of if that players move were to happen

        // hit some other players body
        const owner_id = try self.owners.ownerAt(p_next_pos) orelse {
            // cell is empty next_pos can be applied
            next_pos[i] = p_next_pos;
            continue;
        };
        if (owner_id != pid.id) {
            next_pos[i] = null;
            continue;
        }
        // collides with theirself and that there tail stays because they are the max size already
        if ((try self.owners.ownerAt(p_next_pos)).? == pid.id and std.meta.eql(p.body.tail().?, p_next_pos) and p.body.count != max_snakes_len) {
            next_pos[i] = null;
            continue;
        }
        next_pos[i] = p_next_pos;
    }
    // then apply correct result of advancing each player
    // every next_pos == null the player dies
    for (next_pos, 0..) |maybe_pos, i| {
        // continue if not active player
        var p = if (self.players[i]) |*p| p else continue;

        // just a lil sanity check
        assert(!p.is_dead);
        const pid = p.id;
        // if active but next pos is null meaning invalid kill player and clean up
        const pos = maybe_pos orelse {
            // do some clean up and kill player
            var piter = p.body.iter();
            while (piter.next()) |pos| {
                try self.owners.clear(pos, pid);
            }

            p.die();
            continue;
        };
        try p.body.pushHead(pos);
        try self.owners.claim(pos, pid);
    }
}
test "iterate through players snakes body" {
    var ring: Ring = .empty;
    ring.start = 2998;
    for (0..5) |i| try ring.pushHead(.{ .x = 0, .y = @intCast(i) });

    const start_pos = core.Position{ .x = 0, .y = 0 };
    const end_pos = core.Position{ .x = 0, .y = 4 };
    var it = ring.iter();
    var i: u8 = 0;
    while (i <= 5) : (i += 1) {
        const pos = it.next() orelse null;
        if (i == 0) try t.expectEqual(start_pos, pos);
        if (i == 4) try t.expectEqual(end_pos, pos);
        if (i == 5) try t.expectEqual(null, pos);
    }
}

test "spawn a br player" {
    var br = Br.init;
    try t.expectEqual(0, br.player_count);

    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    const pid = try PlayerId.init(br.player_count + 1);
    const pos = core.Position{ .x = 0, .y = 0 };

    try br.spawnPlayerAt(pid, pos, rand);
    try t.expectEqual(1, br.player_count);
    try t.expectEqual(
        error.PlayerIdAlreadyExists,
        br.spawnPlayerAt(pid, pos, rand),
    );

    try t.expectEqual(1, try br.owners.ownerAt(pos));
}

test "tick grows one player into an empty cell" {
    var br = Br.init;
    const player_id = try PlayerId.init(1);
    const start: core.Position = .{ .x = 10, .y = 10 };
    const next: core.Position = .{ .x = 11, .y = 10 };
    var prng = std.Random.DefaultPrng.init(0);

    try br.spawnPlayerAt(player_id, start, prng.random());
    br.players[0].?.direction = .right;

    try br.tick();

    const player = br.players[0].?;
    try t.expect(!player.is_dead);
    try t.expectEqual(2, player.body.count);
    try t.expectEqual(start, player.body.tail().?);
    try t.expectEqual(next, player.body.head().?);
    try t.expectEqual(player_id.id, (try br.owners.ownerAt(start)).?);
    try t.expectEqual(player_id.id, (try br.owners.ownerAt(next)).?);
}

test "random spawn retries an occupied sampled cell" {
    const seed: u64 = 0xC0FFEE;
    var expected_prng = std.Random.DefaultPrng.init(seed);
    const expected_rand = expected_prng.random();
    const first_pos: core.Position = .{
        .x = expected_rand.intRangeLessThan(u16, 0, max_width - 10),
        .y = expected_rand.intRangeLessThan(u16, 0, max_height - 10),
    };
    const second_pos: core.Position = .{
        .x = expected_rand.intRangeLessThan(u16, 0, max_width - 10),
        .y = expected_rand.intRangeLessThan(u16, 0, max_height - 10),
    };
    try t.expect(!std.meta.eql(first_pos, second_pos));

    var br = Br.init;
    const first_player = try PlayerId.init(1);
    const second_player = try PlayerId.init(2);
    var blocker_prng = std.Random.DefaultPrng.init(0);
    try br.spawnPlayerAt(first_player, first_pos, blocker_prng.random());

    var spawn_prng = std.Random.DefaultPrng.init(seed);
    try br.spawnPlayer(second_player, spawn_prng.random());

    const second = br.players[second_player.id - 1].?;
    try t.expectEqual(second_pos, second.body.head().?);
    try t.expectEqual(first_player.id, (try br.owners.ownerAt(first_pos)).?);
    try t.expectEqual(second_player.id, (try br.owners.ownerAt(second_pos)).?);
}

test "roundtrip occupancy test" {
    var owners: Occupancy = .init;
    const cell: core.Position = .{ .x = 0, .y = 0 };

    try t.expect(try owners.isEmpty(cell));

    const p = try PlayerId.init(88);

    try owners.claim(cell, p);
    try t.expect(!try owners.isEmpty(cell));

    try t.expectEqual(88, (try owners.ownerAt(cell)).?);
    try t.expectEqual(error.CellOccupied, owners.claim(cell, p));
    try t.expectEqual(error.OutOfBounds, owners.isEmpty(.{ .x = 1001, .y = 0 }));
}

test "clear cell test" {
    var owners: Occupancy = .init;
    const cell: core.Position = .{ .x = 0, .y = 9 };

    const p1 = try PlayerId.init(1);
    const p2 = try PlayerId.init(2);

    try owners.claim(cell, p1);
    try t.expectEqual(error.WrongOwner, owners.clear(cell, p2));
    try owners.clear(cell, p1);
    try t.expect(try owners.isEmpty(cell));
}

test "posToIdx maps rows and rejects off-board cells" {
    try t.expectEqual(0, try Occupancy.posToIdx(.{ .x = 0, .y = 0 }));
    try t.expectEqual(10_003, try Occupancy.posToIdx(.{ .x = 3, .y = 10 }));
    try t.expectEqual(999, try Occupancy.posToIdx(.{ .x = 999, .y = 0 }));
    try t.expectEqual(1_000, try Occupancy.posToIdx(.{ .x = 0, .y = 1 }));
    try t.expectEqual(999_999, try Occupancy.posToIdx(.{ .x = 999, .y = 999 }));
    try t.expectError(
        error.OutOfBounds,
        Occupancy.posToIdx(.{ .x = 1000, .y = 0 }),
    );
    try t.expectError(
        error.OutOfBounds,
        Occupancy.posToIdx(.{ .x = 0, .y = 1000 }),
    );
}

test "player id" {
    try t.expectEqual(error.NotValidId, PlayerId.init(0));
    try t.expectEqual(error.NotValidId, PlayerId.init(101));
    const p = try PlayerId.init(88);
    try t.expectEqual(88, p.id);
}

test "add head to an empty ring" {
    var ring: Ring = .empty;

    try ring.pushHead(.{ .x = 0, .y = 0 });
    try t.expectEqual(core.Position{ .x = 0, .y = 0 }, ring.head().?);
    try t.expectEqual(core.Position{ .x = 0, .y = 0 }, ring.tail().?);

    try t.expectEqual(1, ring.count);

    try ring.popTail();
    try t.expect(ring.isEmpty());
    try t.expectEqual(0, ring.count);
    try t.expectEqual(error.NoBody, ring.popTail());
}

test "the wrapping mech of the ring" {
    var ring: Ring = .empty;
    ring.start = ring.body.len - 1;

    try ring.pushHead(.{ .x = 0, .y = 0 });
    try ring.pushHead(.{ .x = 0, .y = 1 });
    try ring.pushHead(.{ .x = 0, .y = 2 });
    try ring.pushHead(.{ .x = 0, .y = 3 });
    try ring.pushHead(.{ .x = 0, .y = 4 });
    try ring.pushHead(.{ .x = 0, .y = 5 });

    try t.expectEqual(core.Position{ .x = 0, .y = 5 }, ring.head().?);
    try t.expectEqual(core.Position{ .x = 0, .y = 0 }, ring.tail().?);

    try ring.popTail();
    try t.expectEqual(core.Position{ .x = 0, .y = 5 }, ring.head().?);
    try t.expectEqual(core.Position{ .x = 0, .y = 1 }, ring.tail().?);
}

test "3001 push fails" {
    var ring: Ring = .empty;

    for (0..3000) |i| try ring.pushHead(.{ .x = 0, .y = @intCast(i) });
    try t.expectEqual(error.BodyFull, ring.pushHead(.{ .x = 0, .y = 0 }));
    try t.expectEqual(3000, ring.count);
}
