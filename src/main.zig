const std = @import("std");
const core = @import("core.zig");
const print = std.debug.print;
const termios = std.posix.termios;
const STDIN_FILENO = std.posix.STDIN_FILENO;

pub fn render(grid: *core.Grid, game: *core.Game, snake: *core.Snake, food: *core.Food, writer: *std.Io.File.Writer) !void {
    const stdout = &writer.interface;
    const ws = termSize();
    const total_w = grid.WIDTH + 2; // + 2 for left/right borders
    const total_h = grid.HEIGHT + 3; // + 3 for top/bottom borders and score rows
    const left = if (ws.col > total_w) (ws.col - total_w) / 2 else 0;
    const top = if (ws.row > total_h) (ws.row - total_h) / 2 else 0;

    for (snake.body.items) |pos| {
        grid.cells[@intCast(pos.y)][@intCast(pos.x)] = core.Cell.snake;
    }
    grid.cells[@intCast(food.pos.y)][@intCast(food.pos.x)] = core.Cell.food;

    // wipe the screen so shifted content leaves no ghosts, then draw each
    // line at an absolute (row, col) — every line positions itself because
    // \r would otherwise snap the cursor back to column 0 and kill centering.
    try stdout.print("\x1b[2J", .{});
    var line: u16 = top;

    try stdout.print("\x1b[{};{}HScore: {}", .{ line, left, game.score });
    line += 1;

    try stdout.print("\x1b[{};{}H┌", .{ line, left });
    for (0..grid.WIDTH) |_| try stdout.print("─", .{});
    try stdout.print("┐", .{});
    line += 1;

    for (0..grid.HEIGHT) |row| {
        try stdout.print("\x1b[{};{}H│", .{ line, left });
        for (0..grid.WIDTH) |col| {
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
    for (0..grid.WIDTH) |_| try stdout.print("─", .{});
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
    var game = core.Game{ .score = 0, .state = .running };
    var snake = try core.Snake.init(gpa);
    var food = core.Food.new(rand);
    defer _ = debug.deinit();
    defer snake.deinit(gpa);

    var grid = core.Grid.init();

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
                food = core.Food.new(rand);
            },
            .over => break,
            else => {},
        }
        try render(&grid, &game, &snake, &food, &stdout_writer);
        try stdout.flush();
    }
}
