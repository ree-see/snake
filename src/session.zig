const std = @import("std");
const tgpa = std.testing.allocator;
const t = std.testing;
const tio = std.testing.io;

const core = @import("core.zig");
const ws = @import("websocket.zig");

pub const SessionManager = struct {
    mutex: std.Io.Mutex,
    sessions: std.ArrayList(*Session),

    pub fn init() SessionManager {
        const sessions = std.ArrayList(*Session).empty;
        const mutex = std.Io.Mutex.init;

        const sman: SessionManager = .{ .mutex = mutex, .sessions = sessions };
        return sman;
    }

    pub fn deinit(self: *SessionManager, alloc: std.mem.Allocator) void {
        for (self.sessions.items) |session| {
            session.deinit();
            alloc.destroy(session);
        }
        self.sessions.deinit(alloc);
    }

    pub fn findOrCreateSession(self: *SessionManager, alloc: std.mem.Allocator, io: std.Io) !*Session {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        for (self.sessions.items) |session| {
            if (session.canJoin()) return session;
            continue;
        }
        try self.addSessionLocked(alloc);

        return self.sessions.getLast();
    }

    pub fn addSession(self: *SessionManager, alloc: std.mem.Allocator, io: std.Io) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const s_ptr = try alloc.create(Session);
        s_ptr.* = try Session.init(alloc);
        try self.sessions.append(alloc, s_ptr);
    }

    pub fn addSessionLocked(self: *SessionManager, alloc: std.mem.Allocator) !void {
        const s_ptr = try alloc.create(Session);
        s_ptr.* = try Session.init(alloc);
        try self.sessions.append(alloc, s_ptr);
    }

    pub fn removeSession(self: *SessionManager, alloc: std.mem.Allocator, io: std.Io, s: *Session) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        for (self.sessions.items, 0..self.sessions.items.len) |session, i| {
            if (s == session) {
                session.deinit();
                alloc.destroy(session);
                _ = self.sessions.swapRemove(i);
                break;
            }
        }
    }

    pub fn removeSessionLocked(self: *SessionManager, alloc: std.mem.Allocator, s: *Session) void {
        for (self.sessions.items, 0..self.sessions.items.len) |session, i| {
            if (s == session) {
                session.deinit();
                alloc.destroy(session);
                _ = self.sessions.swapRemove(i);
                break;
            }
        }
    }
};

test "able to find sessions lobby that's not full" {
    var sman = SessionManager.init();
    defer sman.deinit(tgpa);

    const a_ptr = try tgpa.create(Session);
    a_ptr.* = try Session.init(tgpa);
    try sman.sessions.append(tgpa, a_ptr);
    const open_session = sman.findOrCreateSession(tgpa, tio);

    try t.expectEqual(a_ptr, open_session);
}

test "add new session" {
    var sman = SessionManager.init();
    defer sman.deinit(tgpa);

    try sman.addSession(tgpa, tio);

    try t.expectEqual(sman.sessions.items.len, 1);
}

test "remove new session" {
    var sman = SessionManager.init();
    defer sman.deinit(tgpa);

    try sman.addSession(tgpa, tio);
    const s = sman.sessions.items[0];
    try sman.removeSession(tgpa, tio, s);

    try t.expectEqual(sman.sessions.items.len, 0);
}

pub const Session = struct {
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex,
    game: core.TronGame,
    players: [core.TronGame.n_snakes]?Player,
    queue: MessageQueue,
    count: u64 = 0,

    const SessionError = error{
        LockedMutex,
        LobbyFull,
    };

    pub fn init(alloc: std.mem.Allocator) !Session {
        const game = try core.TronGame.init(alloc);
        const players: [core.TronGame.n_snakes]?Player = [_]?Player{null} ** core.TronGame.n_snakes;
        const queue = MessageQueue.init(alloc, 64);
        const mutex = std.Io.Mutex.init;

        return .{
            .alloc = alloc,
            .mutex = mutex,
            .game = game,
            .players = players,
            .queue = queue,
        };
    }

    pub fn deinit(self: *Session) void {
        self.game.deinit(self.alloc);
        self.queue.deinit(self.alloc);
    }

    pub fn canJoin(self: *Session, io: std.Io) SessionError!bool {
        self.mutex.lock(io) catch SessionError.LockedMutex;
        self.mutex.unlock(io);
        return self.game.state == .lobby and !self.isFull();
    }

    pub fn canJoinLocked(self: *Session) bool {
        return self.game.state == .lobby and !self.isFullLocked();
    }

    pub fn drain(self: *Session, io: std.Io) SessionError!void {
        self.mutex.lock(io) catch return Session.SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        while (true) {
            if (self.queue.pop()) |m| {
                const s = self.game.snakes.slice();
                const prev_dir = s.items(.direction)[m.idx];
                s.items(.direction)[m.idx] = core.setDirection(prev_dir, m.key_pressed);
            } else break;
        }
    }

    pub fn drainLocked(self: *Session) void {
        while (true) {
            if (self.queue.pop()) |m| {
                const s = self.game.snakes.slice();
                const prev_dir = s.items(.direction)[m.idx];
                s.items(.direction)[m.idx] = core.setDirection(prev_dir, m.key_pressed);
            } else break;
        }
    }

    pub fn addPlayer(self: *Session, io: std.Io, w: *std.Io.Writer) SessionError!usize {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        for (self.players, 0..) |player, i| {
            if (player != null) continue;
            const new_player = Player.new(self.count, w);
            self.players[i] = new_player;
            self.players[i].?.assignSnake(i);
            self.count += 1;
            return i;
        }

        return SessionError.LobbyFull;
    }

    pub fn addPlayerLocked(self: *Session, w: *std.Io.Writer) usize {
        for (self.players, 0..) |player, i| {
            if (player != null) continue;
            const new_player = Player.new(self.count, w);
            self.players[i] = new_player;
            self.players[i].?.assignSnake(i);
            self.count += 1;
            return i;
        }

        return SessionError.LobbyFull;
    }

    pub fn isFull(self: *Session, io: std.Io) SessionError!bool {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        for (self.players) |player| {
            if (player == null) {
                return false;
            }
        }
        return true;
    }

    pub fn isFullLocked(self: *Session) bool {
        for (self.players) |player| {
            if (player == null) {
                return false;
            }
        }
        return true;
    }

    pub fn startGame(self: *Session, io: std.Io) SessionError!void {
        self.game.state = .running;
        while (self.game.state != .over) {
            try self.drain(io);
            self.game.tick(self.alloc) catch |err| {
                std.debug.print("{}", .{err});
                self.endGame();
            };

            // broadcast next render frame
            const payload = self.game.encodeDeltas();
            for (self.players) |maybe_player| {
                const p = maybe_player orelse continue;
                try ws.writeFrame(p.writer, &payload);
            }
            if (self.game.state == .over) {
                break;
            }
        }
    }

    pub fn endGame(self: *Session) void {
        self.game.state = .over;
    }

    pub fn startLobby(self: *Session, io: std.Io) !void {
        while (!self.isFull()) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), std.Io.Clock.awake) catch return;
        } else {
            self.game.state = .running;
        }
    }

    pub fn run(self: *Session, io: std.Io) !void {
        try self.startLobby(io);
        self.startGame(io);
    }
};

pub const Player = struct {
    id: u64,
    writer: *std.Io.Writer,
    snake: ?usize,

    pub fn new(id: u64, w: *std.Io.Writer) Player {
        return .{ .id = id, .writer = w, .snake = null };
    }

    pub fn assignSnake(self: *Player, idx: usize) void {
        self.snake = idx;
    }
};

// message queue that collects the message from clients that is owned
const MessageQueue = struct {
    queue: std.Deque(Message),

    const Message = struct {
        idx: usize,
        key_pressed: u8,
    };

    pub fn init(alloc: std.mem.Allocator, capacity: usize) MessageQueue {
        const queue = std.Deque(Message).initCapacity(alloc, capacity) catch unreachable;
        return .{ .queue = queue };
    }

    pub fn deinit(self: *MessageQueue, alloc: std.mem.Allocator) void {
        self.queue.deinit(alloc);
    }

    // add new message to the back of the queue
    pub fn push(self: *MessageQueue, alloc: std.mem.Allocator, io: std.Io, message: Message) Session.SessionError!void {
        self.mutex.lock(io) catch return Session.SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        try self.queue.pushBack(alloc, message);
    }

    pub fn pushLocked(self: *MessageQueue, alloc: std.mem.Allocator, message: Message) !void {
        try self.queue.pushBack(alloc, message);
    }

    // remove the message at the front of the queue
    pub fn pop(self: *MessageQueue) ?Message {
        return self.queue.popFront();
    }

    pub fn len(self: *MessageQueue) usize {
        return self.queue.len;
    }
};

test "drain changes the direction of snakes" {
    var s = try Session.init(tgpa);
    defer s.deinit();

    try s.queue.push(tgpa, .{ .idx = 2, .key_pressed = 107 });
    try s.queue.push(tgpa, .{ .idx = 1, .key_pressed = 108 });
    try s.queue.push(tgpa, .{ .idx = 4, .key_pressed = 107 });
    try s.drain(tio);

    const snakes = s.game.snakes.slice();
    try t.expectEqual(.down, snakes.items(.direction)[2]);
    try t.expectEqual(.right, snakes.items(.direction)[1]);
    try t.expectEqual(.down, snakes.items(.direction)[4]);
}

test "pop message off of queue" {
    var queue = MessageQueue.init(tgpa, 8);
    defer queue.deinit(tgpa);

    try queue.push(tgpa, .{ .idx = 2, .key_pressed = 107 });
    try queue.push(tgpa, .{ .idx = 1, .key_pressed = 107 });
    try queue.push(tgpa, .{ .idx = 4, .key_pressed = 108 });

    try t.expectEqual(2, queue.pop().?.idx);
}

test "push message to queue" {
    var queue = MessageQueue.init(tgpa, 8);
    defer queue.deinit(tgpa);

    try queue.push(tgpa, .{ .idx = 2, .key_pressed = 107 }); // 1
    try queue.push(tgpa, .{ .idx = 1, .key_pressed = 107 }); // 2
    try queue.push(tgpa, .{ .idx = 4, .key_pressed = 108 }); // 3

    try t.expectEqual(3, queue.len());
}

test "drain messages in queue" {
    var s = try Session.init(tgpa);
    defer s.deinit();

    try s.queue.push(tgpa, .{ .idx = 2, .key_pressed = 107 });
    try s.queue.push(tgpa, .{ .idx = 1, .key_pressed = 107 });
    try s.queue.push(tgpa, .{ .idx = 4, .key_pressed = 108 });
    try s.drain(tio);

    try t.expectEqual(0, s.queue.len());
}

test "is lobby full" {
    var s = try Session.init(tgpa);
    defer s.deinit();

    var t_buf: [256]u8 = undefined;
    var t_w = std.Io.Writer.fixed(&t_buf);

    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);

    try t.expect(s.isFull());
}

test "is lobby full error" {
    var s = try Session.init(tgpa);
    defer s.deinit();

    var t_buf: [256]u8 = undefined;
    var t_w = std.Io.Writer.fixed(&t_buf);

    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);

    const full_lobby_err = s.addPlayer(tio, &t_w) catch |err| err;

    try t.expectError(Session.SessionError.LobbyFull, full_lobby_err);
}

test "is lobby full and game switched to running" {
    var s = try Session.init(tgpa);
    defer s.deinit();

    var t_buf: [256]u8 = undefined;
    var t_w = std.Io.Writer.fixed(&t_buf);

    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);
    _ = try s.addPlayer(tio, &t_w);

    try s.startLobby(tio);
    try t.expectEqual(s.game.state, core.GameState.running);
}

fn test_addPlayer(arr: *[8]Session.SessionError!usize, s: *Session, count: usize) void {
    var t_buf: [256]u8 = undefined;
    var t_w = std.Io.Writer.fixed(&t_buf);
    const res = s.addPlayer(tio, &t_w);
    arr[count] = res;
}

// test never proved pre locking the session for addPlayer caused race cond
test "8 players racing to fill one session" {
    for (0..100) |_| {
        var s = try Session.init(tgpa);
        defer s.deinit();
        var actual: [8]Session.SessionError!usize = undefined;

        var threads: [8]std.Thread = undefined;
        for (0..8) |i| {
            threads[i] = try std.Thread.spawn(.{}, test_addPlayer, .{ &actual, &s, i });
        }
        for (0..8) |i| {
            threads[i].join();
        }

        const expected: [8]Session.SessionError!usize = .{
            0,
            1,
            2,
            3,
            4,
            Session.SessionError.LobbyFull,
            Session.SessionError.LobbyFull,
            Session.SessionError.LobbyFull,
        };

        try t.expectEqual(expected, actual);
    }
}
