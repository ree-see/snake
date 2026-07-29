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

snakes: [max_players]BrPlayer,
owners: Occupancy,

const BrPlayer = struct {
    id: PlayerId,
    direction: core.Snake.Direction,
    is_dead: bool,
    kills: u8 = 0,
    body: Ring,

    pub const init: BrPlayer = .{
        .id = undefined,
        .direction = undefined,
        .is_dead = false,
        .body = .empty,
    };
};

const PlayerId = struct {
    id: u8,

    pub fn init(with_id: u8) !PlayerId {
        if (with_id == 0 or with_id > 100) return error.NotValidId;
        return .{ .id = with_id };
    }
};

const Occupancy = struct {
    // 0 is empty cell, 1..100 = PlayerId
    cells: [max_width * max_height]u8,

    pub const init: Occupancy = .{ .cells = [_]u8{0} ** 1_000_000 };

    /// maps a position to a linear idx y * max_width + x
    ///
    /// [0..1000] => x = 0..999, y = 0
    /// [999_000..1_000_000] x = 0..999, y = 999
    pub fn posToIdx(pos: core.Position) !usize {
        if (pos.x >= max_width or pos.y >= max_height) return error.OutOfBounds;

        return @as(usize, pos.y) * max_width + pos.x;
    }

    /// returns false if pos is 0 returns true if pos is 1-100
    pub fn isEmpty(self: *Occupancy, pos: core.Position) !bool {
        const idx = posToIdx(pos) catch |e| return e;

        return self.cells[idx] == 0;
    }

    pub fn ownerAt(self: *Occupancy, pos: core.Position) !?u8 {
        const idx = posToIdx(pos) catch |e| return e;
        if (try self.isEmpty(pos)) return null;
        return self.cells[idx];
    }

    pub fn claim(self: *Occupancy, pos: core.Position, player_id: PlayerId) !void {
        const idx = posToIdx(pos) catch |e| return e;
        if (self.cells[idx] != 0) return error.CellOccupied;
        self.cells[idx] = player_id.id;
    }

    pub fn clear(self: *Occupancy, pos: core.Position, expected_owner: PlayerId) !void {
        const idx = posToIdx(pos) catch |e| return e;
        if (self.cells[idx] != expected_owner.id) return error.WrongOwner;
        self.cells[idx] = 0;
    }
};

const Ring = struct {
    body: [max_snakes_len]core.Position,
    count: u16 = 0, // num of live positions
    start: u16 = 0, // tail idx in the body

    pub const empty: Ring = .{ .body = undefined };

    pub fn isEmpty(self: *Ring) bool {
        return self.count == 0;
    }
    pub fn pushHead(self: *Ring, pos: core.Position) !void {
        if (self.count == 3000) return error.BodyFull;
        self.body[(self.start + self.count) % 3000] = pos;
        self.count += 1;
    }

    pub fn popTail(self: *Ring) !void {
        if (self.isEmpty() or self.tail() == null) return error.NoBody;

        self.start = @intCast((self.start + 1) % self.body.len);
        self.count -= 1;
    }

    pub fn tail(self: *Ring) ?core.Position {
        if (self.isEmpty()) return null;
        return self.body[self.start];
    }

    pub fn head(self: *Ring) ?core.Position {
        if (self.isEmpty()) return null;
        return self.body[(self.count + self.start - 1) % self.body.len];
    }
};

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
