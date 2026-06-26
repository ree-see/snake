const std = @import("std");
const print = std.debug.print;
const termios = std.posix.termios;
const STDIN_FILENO = std.posix.STDIN_FILENO;

const Position = struct {
    x: u8,
    y: u8,
};

const Cell = enum {
    snake,
    food,
    empty,
};

const Food = struct {
    pos: Position,

    pub fn new(rand: std.Random) Food {
        const x = rand.intRangeLessThan(u8, 0, Grid.WIDTH);
        const y = rand.intRangeLessThan(u8, 0, Grid.HEIGHT);
        return Food{ .pos = Position{ .x = x, .y = y } };
    }
};

const Game = struct {
    score: u8,
    state: GameState,
};

const GameState = enum {
    paused,
    running,
    food_ate, // really don't like this in the game state
    over,
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

const Direction = enum {
    left,
    right,
    up,
    down,
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

pub fn render(grid: *Grid, game: *Game, snake: *Snake, food: *Food, writer: *std.Io.File.Writer) !void {
    const stdout = &writer.interface;
    const ws = termSize();
    const total_w = Grid.WIDTH + 2; // + 2 for left/right borders
    const total_h = Grid.HEIGHT + 3; // + 3 for top/bottom borders and score rows
    const left = if (ws.col > total_w) (ws.col - total_w) / 2 else 0;
    const top = if (ws.row > total_h) (ws.row - total_h) / 2 else 0;

    for (snake.body.items) |pos| {
        grid.cells[@intCast(pos.y)][@intCast(pos.x)] = Cell.snake;
    }
    grid.cells[@intCast(food.pos.y)][@intCast(food.pos.x)] = Cell.food;

    // wipe the screen so shifted content leaves no ghosts, then draw each
    // line at an absolute (row, col) — every line positions itself because
    // \r would otherwise snap the cursor back to column 0 and kill centering.
    try stdout.print("\x1b[2J", .{});
    var line: u16 = top;

    try stdout.print("\x1b[{};{}HScore: {}", .{ line, left, game.score });
    line += 1;

    try stdout.print("\x1b[{};{}H┌", .{ line, left });
    for (0..Grid.WIDTH) |_| try stdout.print("─", .{});
    try stdout.print("┐", .{});
    line += 1;

    for (0..Grid.HEIGHT) |row| {
        try stdout.print("\x1b[{};{}H│", .{ line, left });
        for (0..Grid.WIDTH) |col| {
            const cell = grid.cells[row][col];
            switch (cell) {
                .empty => try stdout.print(" ", .{}),
                .snake => try stdout.print("▢", .{}),
                .food => try stdout.print("⛦", .{}),
            }
        }
        try stdout.print("│", .{});
        line += 1;
    }

    try stdout.print("\x1b[{};{}H└", .{ line, left });
    for (0..Grid.WIDTH) |_| try stdout.print("─", .{});
    try stdout.print("┘", .{});

    grid.clear();
    try stdout.flush();
}

pub fn enableRawMode() !termios {
    const term = try std.posix.tcgetattr(STDIN_FILENO);
    var raw = term;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 2;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;

    try std.posix.tcsetattr(STDIN_FILENO, .FLUSH, raw);
    return term;
}

pub fn disableRawMode(term: termios) !void {
    try std.posix.tcsetattr(STDIN_FILENO, .FLUSH, term);
}

pub fn termSize() std.posix.winsize {
    var ws: std.posix.winsize = undefined;
    _ = std.c.ioctl(STDIN_FILENO, @intCast(std.c.T.IOCGWINSZ), &ws);
    return ws;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [0x100]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var debug = std.heap.DebugAllocator(.{}){};
    const gpa = debug.allocator();

    // terminal setup for raw mode
    const term = try enableRawMode();
    defer disableRawMode(term) catch {};

    // enter alternate screen + hide cursor; restore both on exit (LIFO defer)
    try stdout.print("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H", .{});
    try stdout.flush();
    defer {
        stdout.print("\x1b[?25h\x1b[?1049l", .{}) catch {};
        stdout.flush() catch {};
    }

    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var game = Game{ .score = 0, .state = .running };
    var snake = try Snake.init(gpa);
    var food = Food.new(rand);
    defer _ = debug.deinit();
    defer snake.deinit(gpa);

    var grid = Grid.init();

    var buf: [1]u8 = undefined;
    while (true) {
        const n = try std.posix.read(STDIN_FILENO, &buf);
        if (n > 0) {
            if (buf[0] == '\x1b') break;
            snake.setDirection(buf[0]);
        }
        switch (try snake.step(gpa, &food)) {
            .food_ate => {
                game.score += 1;
                food = Food.new(rand);
            },
            .over => break,
            else => {},
        }
        try render(&grid, &game, &snake, &food, &stdout_writer);
        try stdout.flush();
    }
}

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
