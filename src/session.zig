const std = @import("std");
const talloc = std.testing.allocator;
const t = std.testing;
const tio = std.testing.io;

const core = @import("core");

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
            if (try session.canJoin(io)) return session;
            continue;
        }
        try self.addSessionLocked(alloc);
        const new_session = self.sessions.getLast();

        if (std.Thread.spawn(.{}, Session.run, .{ new_session, io })) |thread| {
            thread.detach();
        } else |err| {
            std.debug.print("{}", .{err});
        }

        return new_session;
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
    defer sman.deinit(talloc);

    const a_ptr = try talloc.create(Session);
    a_ptr.* = try Session.init(talloc);
    try sman.sessions.append(talloc, a_ptr);
    const open_session = sman.findOrCreateSession(talloc, tio);

    try t.expectEqual(a_ptr, open_session);
}

test "add new session" {
    var sman = SessionManager.init();
    defer sman.deinit(talloc);

    try sman.addSession(talloc, tio);

    try t.expectEqual(sman.sessions.items.len, 1);
}

test "remove new session" {
    var sman = SessionManager.init();
    defer sman.deinit(talloc);

    try sman.addSession(talloc, tio);
    const s = sman.sessions.items[0];
    try sman.removeSession(talloc, tio, s);

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
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        self.mutex.unlock(io);
        return self.canJoinLocked();
    }

    pub fn canJoinLocked(self: *Session) bool {
        return self.game.state == .lobby and !self.isFullLocked();
    }

    pub fn drain(self: *Session, io: std.Io) SessionError!void {
        self.mutex.lock(io) catch return Session.SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.drainLocked();
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

    pub fn addPlayer(self: *Session, io: std.Io, ws: *std.http.Server.WebSocket) SessionError!usize {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.addPlayerLocked(ws);
    }

    pub fn addPlayerLocked(self: *Session, ws: *std.http.Server.WebSocket) SessionError!usize {
        for (self.players, 0..) |player, i| {
            if (player != null) continue;
            const new_player = Player.new(self.count, ws);
            self.players[i] = new_player;
            self.players[i].?.assignSnake(i);
            self.count += 1;
            return i;
        }

        return SessionError.LobbyFull;
    }

    pub fn removePlayer(self: *Session, io: std.Io, players_idx: usize) SessionError!void {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.removePlayerLocked(players_idx);
    }

    pub fn removePlayerLocked(self: *Session, players_idx: usize) void {
        self.players[players_idx] = null;
    }

    pub fn isFull(self: *Session, io: std.Io) SessionError!bool {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.isFullLocked();
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
        var dead_count: u4 = 0;
        var winner_idx: u8 = undefined;

        const s = self.game.snakes.slice();
        const dead = s.items(.is_dead);
        while (self.game.state != .over) {
            dead_count = 0;
            try self.drain(io);
            self.game.tick(self.alloc) catch |err| {
                std.debug.print("{}", .{err});
                self.endGame();
            };
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), std.Io.Clock.awake) catch return;
            // broadcast next render frame
            const payload = self.game.encodeDeltas();

            self.broadcast(io, &payload, .text) catch |err| std.log.err("{}", .{err});
            for (dead, 0..) |is_dead, i| {
                if (is_dead) {
                    dead_count += 1;
                    continue;
                }
                if (dead_count == 4) {
                    winner_idx = @intCast(i);
                }
            }
        }

        var buf: [20]u8 = undefined;
        var msg: []u8 = undefined;
        if (dead_count == 4) {
            msg = std.fmt.bufPrint(&buf, "{{ \"winner\": {d} }}", .{winner_idx}) catch unreachable;
        } else {
            msg = std.fmt.bufPrint(&buf, "{{ \"winner\": 5 }}", .{}) catch unreachable;
        }

        self.broadcast(io, msg, .text) catch |err| std.log.err("{}", .{err});
    }

    pub fn broadcast(self: *Session, io: std.Io, msg: []const u8, op: std.http.Server.WebSocket.Opcode) SessionError!void {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        self.broadcastLocked(msg, op);
    }

    pub fn broadcastLocked(self: *Session, msg: []const u8, op: std.http.Server.WebSocket.Opcode) void {
        for (self.players) |maybe_player| {
            const p = maybe_player orelse continue;
            p.ws.writeMessage(msg, op) catch |err| {
                std.debug.print("{}", .{err});
                return;
            };
        }
    }

    pub fn endGame(self: *Session) void {
        self.game.state = .over;
    }

    pub fn startLobby(self: *Session, io: std.Io, countdown: usize) SessionError!void {
        while (!try self.isFull(io)) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), std.Io.Clock.awake) catch return;
        } else {
            for (1..countdown + 1) |i| {
                std.Io.sleep(io, std.Io.Duration.fromSeconds(1), std.Io.Clock.awake) catch return;
                var buf: [20]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{{ \"countdown\": {d} }}", .{countdown + 1 - i}) catch unreachable;
                try self.broadcast(io, msg, .text);
            }

            self.game.state = .running;
        }
    }

    pub fn run(self: *Session, io: std.Io) !void {
        try self.startLobby(io, 20);
        try self.startGame(io);
    }

    pub fn pushMessage(self: *Session, io: std.Io, msg: MessageQueue.Message) SessionError!void {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        self.queue.push(self.alloc, msg) catch @panic("OOM error");
    }

    pub fn popMessage(self: *Session, io: std.Io) SessionError!?MessageQueue.Message {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.queue.pop();
    }
};

pub const Player = struct {
    id: u64,
    ws: *std.http.Server.WebSocket,
    snake: ?usize,

    pub fn new(id: u64, ws: *std.http.Server.WebSocket) Player {
        return .{ .id = id, .ws = ws, .snake = null };
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
    // Use Session.pushMessage when race conditions apply
    pub fn push(self: *MessageQueue, alloc: std.mem.Allocator, message: Message) !void {
        try self.queue.pushBack(alloc, message);
    }

    // remove the message at the front of the queue
    // Use Session.popMessage when race conditions apply
    pub fn pop(self: *MessageQueue) ?Message {
        return self.queue.popFront();
    }

    pub fn len(self: *MessageQueue) usize {
        return self.queue.len;
    }
};

test "drain changes the direction of snakes" {
    var s = try Session.init(talloc);
    defer s.deinit();

    try s.queue.push(talloc, .{ .idx = 2, .key_pressed = 107 });
    try s.queue.push(talloc, .{ .idx = 1, .key_pressed = 108 });
    try s.queue.push(talloc, .{ .idx = 4, .key_pressed = 107 });
    try s.drain(tio);

    const snakes = s.game.snakes.slice();
    try t.expectEqual(.down, snakes.items(.direction)[2]);
    try t.expectEqual(.right, snakes.items(.direction)[1]);
    try t.expectEqual(.down, snakes.items(.direction)[4]);
}

test "pop message off of queue" {
    var queue = MessageQueue.init(talloc, 8);
    defer queue.deinit(talloc);

    try queue.push(talloc, .{ .idx = 2, .key_pressed = 107 });
    try queue.push(talloc, .{ .idx = 1, .key_pressed = 107 });
    try queue.push(talloc, .{ .idx = 4, .key_pressed = 108 });

    try t.expectEqual(2, queue.pop().?.idx);
}

test "push message to queue" {
    var queue = MessageQueue.init(talloc, 8);
    defer queue.deinit(talloc);

    try queue.push(talloc, .{ .idx = 2, .key_pressed = 107 }); // 1
    try queue.push(talloc, .{ .idx = 1, .key_pressed = 107 }); // 2
    try queue.push(talloc, .{ .idx = 4, .key_pressed = 108 }); // 3

    try t.expectEqual(3, queue.len());
}

test "drain messages in queue" {
    var s = try Session.init(talloc);
    defer s.deinit();

    try s.queue.push(talloc, .{ .idx = 2, .key_pressed = 107 });
    try s.queue.push(talloc, .{ .idx = 1, .key_pressed = 107 });
    try s.queue.push(talloc, .{ .idx = 4, .key_pressed = 108 });
    try s.drain(tio);

    try t.expectEqual(0, s.queue.len());
}

test "is lobby full" {
    var s = try Session.init(talloc);
    defer s.deinit();

    var t_wbuf: [256]u8 = undefined;
    var t_w = std.Io.Writer.fixed(&t_wbuf);
    var t_rbuf: [256]u8 = undefined;
    var t_r = std.Io.Reader.fixed(&t_rbuf);
    var ws = initTestWs(&t_w, &t_r);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);

    try t.expect(try s.isFull(tio));
}

test "is lobby full error" {
    var s = try Session.init(talloc);
    defer s.deinit();

    var t_wbuf: [256]u8 = undefined;
    var t_w = std.Io.Writer.fixed(&t_wbuf);
    var t_rbuf: [256]u8 = undefined;
    var t_r = std.Io.Reader.fixed(&t_rbuf);
    var ws = initTestWs(&t_w, &t_r);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);

    const full_lobby_err = s.addPlayer(tio, &ws) catch |err| err;

    try t.expectError(Session.SessionError.LobbyFull, full_lobby_err);
}

test "is lobby full and game switched to running" {
    var s = try Session.init(talloc);
    defer s.deinit();

    var t_wbuf: [4096]u8 = undefined;
    var t_w = std.Io.Writer.fixed(&t_wbuf);
    var t_rbuf: [4096]u8 = undefined;
    var t_r = std.Io.Reader.fixed(&t_rbuf);
    var ws = initTestWs(&t_w, &t_r);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);
    _ = try s.addPlayer(tio, &ws);

    try s.startLobby(tio, 1);
    try t.expectEqual(s.game.state, core.GameState.running);
}

test "remove player and replace idx with null" {
    var s = try Session.init(talloc);
    defer s.deinit();

    var t_wbuf: [256]u8 = undefined;
    var t_w = std.Io.Writer.fixed(&t_wbuf);
    var t_rbuf: [256]u8 = undefined;
    var t_r = std.Io.Reader.fixed(&t_rbuf);
    var ws = initTestWs(&t_w, &t_r);
    _ = try s.addPlayer(tio, &ws);
    try s.removePlayer(tio, 0);

    try t.expect((s.players[0] == null));
}

fn test_addPlayer(arr: *[8]Session.SessionError!usize, s: *Session, count: usize) void {
    var t_wbuf: [256]u8 = undefined;
    var t_w = std.Io.Writer.fixed(&t_wbuf);
    var t_rbuf: [256]u8 = undefined;
    var t_r = std.Io.Reader.fixed(&t_rbuf);
    var ws = initTestWs(&t_w, &t_r);
    const res = s.addPlayer(tio, &ws);
    arr[count] = res;
}

// test never proved pre locking the session for addPlayer caused race cond
test "8 players racing to fill one session" {
    for (0..100) |_| {
        var s = try Session.init(talloc);
        defer s.deinit();
        var actual: [8]Session.SessionError!usize = undefined;
        var threads: [8]std.Thread = undefined;
        for (0..8) |i| {
            threads[i] = try std.Thread.spawn(.{}, test_addPlayer, .{ &actual, &s, i });
        }
        for (0..8) |i| {
            threads[i].join();
        }
        var seen: [5]bool = .{false} ** 5;
        var fail_count: u8 = 0;

        for (0..8) |i| {
            const idx: Session.SessionError!usize = actual[i];
            if (idx == Session.SessionError.LobbyFull) {
                fail_count += 1;
                continue;
            }

            if (@TypeOf(idx) == usize) {
                t.expect(!seen[idx]);
                seen[idx] = true;
            }
        }
    }
}

fn initTestWs(w: *std.Io.Writer, r: *std.Io.Reader) std.http.Server.WebSocket {
    return .{
        .key = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        .input = r,
        .output = w,
    };
}
