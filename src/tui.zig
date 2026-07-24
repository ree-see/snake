const std = @import("std");
const core = @import("core");
const games = @import("games");

const print = std.debug.print;
const termios = std.posix.termios;
const STDIN_FILENO = std.posix.STDIN_FILENO;

const Cell = enum {
    snake,
    empty,
    food,
};

const Grid = struct {
    cells: [core.GRID_HEIGHT][core.GRID_WIDTH]Cell,

    pub fn init() Grid {
        const empty_row = [_]Cell{.empty} ** core.GRID_WIDTH;
        const cells = [_][core.GRID_WIDTH]Cell{empty_row} ** core.GRID_HEIGHT;
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
};

pub fn render(
    grid: *Grid,
    game: *games.ClassicGame,
    writer: *std.Io.File.Writer,
) !void {
    const stdout = &writer.interface;
    const ws = termSize();
    const total_w = core.GRID_WIDTH + 2; // + 2 for left/right borders
    const total_h = core.GRID_HEIGHT + 3; // + 3 for top/bottom borders and score rows
    const left = if (ws.col > total_w) (ws.col - total_w) / 2 else 0;
    const top = if (ws.row > total_h) (ws.row - total_h) / 2 else 0;

    for (game.snake.body.items) |pos| {
        grid.cells[@intCast(pos.y)][@intCast(pos.x)] = Cell.snake;
    }

    try stdout.print("\x1b[2J", .{});
    var line: u16 = top;

    try stdout.print("\x1b[{};{}HScore: {}", .{ line, left, game.score });
    line += 1;

    try stdout.print("\x1b[{};{}H┌", .{ line, left });
    for (0..core.GRID_WIDTH) |_| try stdout.print("─", .{});
    try stdout.print("┐", .{});
    line += 1;

    for (0..core.GRID_HEIGHT) |row| {
        try stdout.print("\x1b[{};{}H│", .{ line, left });
        for (0..core.GRID_WIDTH) |col| {
            const cell = grid.cells[row][col];
            switch (cell) {
                .empty => try stdout.print(" ", .{}),
                .snake => try stdout.print("▢", .{}),
                .food => try stdout.print("*", .{}),
            }
        }
        try stdout.print("│", .{});
        line += 1;
    }

    try stdout.print("\x1b[{};{}H└", .{ line, left });
    for (0..core.GRID_WIDTH) |_| try stdout.print("─", .{});
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
    // when calling this make sure to add .is_linking_libc to build.zig
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
    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

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

    var game = try games.ClassicGame.init(gpa, rand);
    defer game.deinit(gpa);
    defer _ = debug.deinit();

    var grid = Grid.init();

    var buf: [1]u8 = undefined;
    while (true) {
        const n = try std.posix.read(STDIN_FILENO, &buf);
        if (n > 0) {
            if (buf[0] == '\x1b') break;
            const prev_dir = game.snake.direction;
            game.snake.direction = core.setDirection(prev_dir, try core.dirFromKeyPress(buf[0]));
        }
        try game.tick(gpa, rand);
        try render(&grid, &game, &stdout_writer);
        if (game.state == .over) break;
        try stdout.flush();
    }
}

test "Grid.clear resets every cell to empty" {
    var grid = Grid.init();
    grid.cells[0][0] = .snake;
    grid.cells[core.GRID_HEIGHT - 1][core.GRID_WIDTH - 1] = .snake;

    grid.clear();

    for (grid.cells) |row| {
        for (row) |cell| try std.testing.expectEqual(Cell.empty, cell);
    }
}
