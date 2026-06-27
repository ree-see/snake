const std = @import("std");

const Game = struct {
    score: u8,
    state: GameState,
};

const GameState = enum {
    food_ate,
    running,
    paused,
    over,
};

const Food = struct {
    pos: Position,

    pub fn new(rand: std.Random) Food {
        const x = rand.intRangeLessThan(u8, 0, Grid.WIDTH);
        const y = rand.intRangeLessThan(u8, 0, Grid.HEIGHT);
        return Food{ .pos = Position{ .x = x, .y = y } };
    }
};

const Direction = enum {
    left,
    right,
    up,
    down,
};

const Position = struct {
    x: u8,
    y: u8,
};

const Cell = enum {
    snake,
    food,
    empty,
};

const Grid = struct {
    cells: [HEIGHT][WIDTH]Cell,

    const WIDTH = 64;
    const HEIGHT = 32;

    pub fn init() Grid {
        const empty_row = [_]Cell{.empty} ** WIDTH;
        const cells = [_][WIDTH]Cell{empty_row} ** HEIGHT;
        return .{ .cells = cells };
    }

    pub fn clear(self: *Grid) void {
        // could also do self.cells = Grid.init().cells;
        for (&self.cells) |*row| {
            for (row) |*col| {
                col.* = .empty;
            }
        }
    }

    pub fn center() Position {
        const x = WIDTH / 2;
        const y = HEIGHT / 2;

        return Position{ .x = x, .y = y };
    }
};

const Snake = struct {
    body: std.ArrayList(Position),
    direction: Direction,

    pub fn init(gpa: std.mem.Allocator) !Snake {
        var body = std.ArrayList(Position).empty;
        const center = Grid.center();

        try body.append(gpa, center);

        return .{
            .body = body,
            .direction = .left,
        };
    }

    pub fn deinit(self: *Snake, gpa: std.mem.Allocator) void {
        self.body.deinit(gpa);
    }

    // returns null for illegal step position on the grid
    // returns position for legal step position on the grid
    pub fn next(self: *Snake) ?Position {
        const head = self.body.items[0];
        const next_pos: ?Position = switch (self.direction) {
            .up => if (head.y == 0) null else Position{ .x = head.x, .y = head.y - 1 },
            .down => if (head.y == Grid.HEIGHT - 1) null else Position{ .x = head.x, .y = head.y + 1 },
            .left => if (head.x == 0) null else Position{ .x = head.x - 1, .y = head.y },
            .right => if (head.x == Grid.WIDTH - 1) null else Position{ .x = head.x + 1, .y = head.y },
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

    pub fn step(self: *Snake, gpa: std.mem.Allocator, food: *Food) !GameState {
        const target = self.next() orelse return .over; // if off grid returns game over if not returns a pos
        if (self.contains(target)) return .over; // self collision check
        try self.body.insert(gpa, 0, target);
        if (target.x == food.pos.x and target.y == food.pos.y) return .food_ate; // checks if target is a food cell
        _ = self.body.pop();
        return .running;
    }
};

// ===========================================================================
// Characterization tests for the simulation core.
//
// These pin the *current* behavior of the platform-agnostic model
// (Snake.next/step/contains, setDirection, Grid.center/clear) before the
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
    snake.body.items[0] = .{ .x = 10, .y = Grid.HEIGHT - 1 };
    snake.direction = .down;
    try expectEqual(@as(?Position, null), snake.next());

    // Left off the first column.
    snake.body.items[0] = .{ .x = 0, .y = 10 };
    snake.direction = .left;
    try expectEqual(@as(?Position, null), snake.next());

    // Right off the last column.
    snake.body.items[0] = .{ .x = Grid.WIDTH - 1, .y = 10 };
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
    var food = Food{ .pos = .{ .x = 63, .y = 31 } };

    try expectEqual(GameState.over, try snake.step(gpa, &food));
}

test "step into own body ends the game" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    // A 2x2 loop: head at {10,10} moving right lands on the tail at {11,10}.
    snake.body.clearRetainingCapacity();
    try snake.body.append(gpa, .{ .x = 10, .y = 10 }); // head
    try snake.body.append(gpa, .{ .x = 10, .y = 11 });
    try snake.body.append(gpa, .{ .x = 11, .y = 11 });
    try snake.body.append(gpa, .{ .x = 11, .y = 10 }); // tail (the cell we hit)
    snake.direction = .right;
    var food = Food{ .pos = .{ .x = 0, .y = 0 } };

    try expectEqual(GameState.over, try snake.step(gpa, &food));
}

test "step onto food grows the snake and keeps the tail" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    snake.body.items[0] = .{ .x = 10, .y = 10 };
    snake.direction = .right;
    var food = Food{ .pos = .{ .x = 11, .y = 10 } }; // exactly the next cell

    const len_before = snake.body.items.len;
    try expectEqual(GameState.food_ate, try snake.step(gpa, &food));
    try expectEqual(len_before + 1, snake.body.items.len); // tail kept -> grew
    try expectEqual(@as(Position, .{ .x = 11, .y = 10 }), snake.body.items[0]);
}

test "step on empty cell moves the snake and pops the tail" {
    const gpa = std.testing.allocator;
    var snake = try Snake.init(gpa);
    defer snake.deinit(gpa);

    snake.body.items[0] = .{ .x = 10, .y = 10 };
    snake.direction = .right;
    var food = Food{ .pos = .{ .x = 50, .y = 5 } }; // somewhere else

    const len_before = snake.body.items.len;
    try expectEqual(GameState.running, try snake.step(gpa, &food));
    try expectEqual(len_before, snake.body.items.len); // tail popped -> same length
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

test "Grid.center is the middle of the board" {
    try expectEqual(@as(Position, .{ .x = Grid.WIDTH / 2, .y = Grid.HEIGHT / 2 }), Grid.center());
}

test "Grid.clear resets every cell to empty" {
    var grid = Grid.init();
    grid.cells[0][0] = .snake;
    grid.cells[5][10] = .food;
    grid.cells[Grid.HEIGHT - 1][Grid.WIDTH - 1] = .snake;

    grid.clear();

    for (grid.cells) |row| {
        for (row) |cell| try expectEqual(Cell.empty, cell);
    }
}
