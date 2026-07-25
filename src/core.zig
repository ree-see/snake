const std = @import("std");

const t = std.testing;
const tio = t.io;
const talloc = t.allocator;

/// Number of addressable columns in every game board.
pub const GRID_WIDTH = 128;
/// Number of addressable rows in every game board.
pub const GRID_HEIGHT = 96;

/// Returns a direction and the opposite corner used for a snake spawn.
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

/// Returns the board's integer center cell.
pub fn gridCenter() Position {
    const x = GRID_WIDTH / 2;
    const y = GRID_HEIGHT / 2;

    return Position{ .x = x, .y = y };
}

/// Returns the adjacent cell in `direction`, or null when it leaves the board.
pub fn nextPos(direction: Snake.Direction, head: Position) ?Position {
    return switch (direction) {
        .up => if (head.y == 0) null else .{
            .x = head.x,
            .y = head.y - 1,
        },
        .down => if (head.y == GRID_HEIGHT - 1) null else .{
            .x = head.x,
            .y = head.y + 1,
        },
        .left => if (head.x == 0) null else .{
            .x = head.x - 1,
            .y = head.y,
        },
        .right => if (head.x == GRID_WIDTH - 1) null else .{
            .x = head.x + 1,
            .y = head.y,
        },
    };
}

/// Reports whether a snake body occupies `target`.
pub fn bodyContains(body: []const Position, target: Position) bool {
    for (body) |pos| {
        if (std.meta.eql(pos, target)) return true;
    }
    return false;
}

/// Applies a turn unless it would directly reverse the current direction.
pub fn setDirection(curr_dir: Snake.Direction, new_dir: Snake.Direction) Snake.Direction {
    return switch (new_dir) {
        .up => if (curr_dir != .down) new_dir else curr_dir,
        .left => if (curr_dir != .right) new_dir else curr_dir,
        .down => if (curr_dir != .up) new_dir else curr_dir,
        .right => if (curr_dir != .left) new_dir else curr_dir,
    };
}

/// Maps the supported i/j/k/l input bytes to a direction.
pub fn dirFromKeyPress(key_press: u8) !Snake.Direction {
    return switch (key_press) {
        105 => .up,
        106 => .left,
        107 => .down,
        108 => .right,
        else => error.NotValidKeyPress,
    };
}

/// Returns the i/j/k/l input byte for a direction.
pub fn keyPressFromDir(dir: Snake.Direction) u8 {
    return switch (dir) {
        .up => 105,
        .left => 106,
        .down => 107,
        .right => 108,
    };
}
/// A grid coordinate shared by native, network, and WASM code.
pub const Position = extern struct {
    x: u8,
    y: u8,
};

/// Mutable simulation state for one snake with its head at body index zero.
pub const Snake = struct {
    is_dead: bool,
    direction: Direction,
    kills: u8,
    body: std.ArrayList(Position),

    /// The four non-diagonal movement directions.
    pub const Direction = enum {
        left,
        right,
        up,
        down,
    };

    /// Creates a live snake at the board center, moving right.
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

    /// Creates a live one-cell snake at a caller-selected position and direction.
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

    /// Releases the snake body allocation using the allocator passed to init.
    pub fn deinit(self: *Snake, gpa: std.mem.Allocator) void {
        self.body.deinit(gpa);
    }

    /// Marks the snake dead and removes every occupied body cell.
    pub fn kill(self: *Snake) void {
        self.is_dead = true;
        self.clearBody();
    }

    /// Prepends a new head cell without changing the tail.
    pub fn addHead(self: *Snake, gpa: std.mem.Allocator, next_pos: Position) !void {
        try self.body.insert(gpa, 0, next_pos);
    }

    /// Removes the last body cell from a non-empty snake.
    pub fn removeTail(self: *Snake) void {
        _ = self.body.pop();
    }

    /// Returns the current number of occupied body cells.
    pub fn len(self: *Snake) usize {
        return self.body.items.len;
    }

    /// Removes all body cells while retaining the allocated capacity.
    pub fn clearBody(self: *Snake) void {
        self.body.clearRetainingCapacity();
    }

    /// Grows the snake by one cell when its next position remains on the board.
    pub fn step(self: *Snake, gpa: std.mem.Allocator) !void {
        if (nextPos(self.direction, self.body.items[0])) |target|
            try self.addHead(gpa, target);
    }
};

test "next returns null at every wall edge" {
    var snake = try Snake.init(talloc);
    defer snake.deinit(talloc);

    // Up off the top row.
    snake.body.items[0] = .{ .x = 10, .y = 0 };
    snake.direction = .up;
    try t.expectEqual(
        @as(?Position, null),
        nextPos(snake.direction, snake.body.items[0]),
    );

    // Down off the bottom row.
    snake.body.items[0] = .{ .x = 10, .y = GRID_HEIGHT - 1 };
    snake.direction = .down;
    try t.expectEqual(
        @as(?Position, null),
        nextPos(snake.direction, snake.body.items[0]),
    );

    // Left off the first column.
    snake.body.items[0] = .{ .x = 0, .y = 10 };
    snake.direction = .left;
    try t.expectEqual(
        @as(?Position, null),
        nextPos(snake.direction, snake.body.items[0]),
    );

    // Right off the last column.
    snake.body.items[0] = .{ .x = GRID_WIDTH - 1, .y = 10 };
    snake.direction = .right;
    try t.expectEqual(
        @as(?Position, null),
        nextPos(snake.direction, snake.body.items[0]),
    );
}

test "next returns the adjacent cell for interior moves" {
    var snake = try Snake.init(talloc);
    defer snake.deinit(talloc);

    snake.body.items[0] = .{ .x = 10, .y = 10 };

    snake.direction = .up;
    try t.expectEqual(
        @as(?Position, .{ .x = 10, .y = 9 }),
        nextPos(snake.direction, snake.body.items[0]),
    );
    snake.direction = .down;
    try t.expectEqual(
        @as(?Position, .{ .x = 10, .y = 11 }),
        nextPos(snake.direction, snake.body.items[0]),
    );
    snake.direction = .left;
    try t.expectEqual(
        @as(?Position, .{ .x = 9, .y = 10 }),
        nextPos(snake.direction, snake.body.items[0]),
    );
    snake.direction = .right;
    try t.expectEqual(
        @as(?Position, .{ .x = 11, .y = 10 }),
        nextPos(snake.direction, snake.body.items[0]),
    );
}

test "contains reports head, body, and misses" {
    var snake = try Snake.init(talloc);
    defer snake.deinit(talloc);

    snake.body.items[0] = .{ .x = 32, .y = 16 }; // head
    try snake.body.append(talloc, .{ .x = 33, .y = 16 }); // a body segment

    try t.expect(bodyContains(snake.body.items, .{ .x = 32, .y = 16 })); // head hit
    try t.expect(bodyContains(snake.body.items, .{ .x = 33, .y = 16 })); // body hit
    try t.expect(!bodyContains(snake.body.items, .{ .x = 0, .y = 0 })); // miss
}

test "step grows the snakes every tick" {
    var snake = try Snake.init(talloc);
    defer snake.deinit(talloc);

    snake.body.items[0] = .{ .x = 10, .y = 10 };
    snake.direction = .right;

    const len_before = snake.len();
    try snake.step(talloc);
    try t.expectEqual(len_before + 1, snake.len());
    try t.expectEqual(@as(Position, .{ .x = 11, .y = 10 }), snake.body.items[0]);
}

test "setDirection ignores reversals into self" {
    var snake = try Snake.init(talloc);
    defer snake.deinit(talloc);

    // Key bytes: 105=up(i), 106=left(j), 107=down(k), 108=right(l).
    snake.direction = .right;
    var curr_dir = snake.direction;
    snake.direction = setDirection(curr_dir, .left); // left key while moving right -> ignored
    try t.expectEqual(Snake.Direction.right, snake.direction);

    snake.direction = .left;
    curr_dir = snake.direction;
    snake.direction = setDirection(curr_dir, .right); // right key while moving left -> ignored
    try t.expectEqual(Snake.Direction.left, snake.direction);

    snake.direction = .up;
    curr_dir = snake.direction;
    snake.direction = setDirection(curr_dir, .down); // down key while moving up -> ignored
    try t.expectEqual(Snake.Direction.up, snake.direction);

    snake.direction = .down;
    curr_dir = snake.direction;
    snake.direction = setDirection(curr_dir, .up); // up key while moving down -> ignored
    try t.expectEqual(Snake.Direction.down, snake.direction);

    // A perpendicular turn is still accepted.
    snake.direction = .right;
    curr_dir = snake.direction;
    snake.direction = setDirection(curr_dir, .up); // up key while moving right -> applied
    try t.expectEqual(Snake.Direction.up, snake.direction);
}

test "gridCenter is the middle of the board" {
    try t.expectEqual(
        @as(Position, .{ .x = GRID_WIDTH / 2, .y = GRID_HEIGHT / 2 }),
        gridCenter(),
    );
}
