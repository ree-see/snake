const std = @import("std");
const core = @import("core");
const games = @import("games");

const talloc = std.testing.allocator;
const t = std.testing;
const tio = std.testing.io;

pub const SessionManager = struct {
    mutex: std.Io.Mutex,
    sessions: std.ArrayList(*Session),

    pub fn init() SessionManager {
        const sessions = std.ArrayList(*Session).empty;
        const mutex = std.Io.Mutex.init;

        const sman: SessionManager = .{
            .mutex = mutex,
            .sessions = sessions,
        };
        return sman;
    }

    pub fn deinit(self: *SessionManager, alloc: std.mem.Allocator, io: std.Io) void {
        for (self.sessions.items) |session| {
            session.deinit(io);
            alloc.destroy(session);
        }
        self.sessions.deinit(alloc);
    }

    pub fn runSession(s: *Session, io: std.Io) std.Io.Cancelable!void {
        s.run(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                std.log.err("session failed: {}", .{err});
                try s.mutex.lock(io);
                defer s.mutex.unlock(io);
                s.game.state = .over;
                return;
            },
        };
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

        new_session.run_group.concurrent(io, runSession, .{
            new_session,
            io,
        }) catch |err| {
            self.destroySessionLocked(alloc, io, new_session);
            return err;
        };

        return new_session;
    }

    // use if SessionManager isn't locked
    pub fn addSession(self: *SessionManager, alloc: std.mem.Allocator, io: std.Io) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const s_ptr = try alloc.create(Session);
        s_ptr.* = try Session.init(alloc);
        try self.sessions.append(alloc, s_ptr);
    }

    // not safe to use make sure SessionManager is locked
    pub fn addSessionLocked(self: *SessionManager, alloc: std.mem.Allocator) !void {
        const s_ptr = try alloc.create(Session);
        s_ptr.* = try Session.init(alloc);
        try self.sessions.append(alloc, s_ptr);
    }

    // use if SessionManager isn't locked
    pub fn removeSession(self: *SessionManager, alloc: std.mem.Allocator, io: std.Io, s: *Session) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.removeSessionLocked(alloc, io, s);
    }

    // not safe to use make sure SessionManager is locked
    pub fn removeSessionLocked(self: *SessionManager, alloc: std.mem.Allocator, io: std.Io, s: *Session) !void {
        if (try s.canRemove(io)) {
            self.destroySessionLocked(alloc, io, s);
        }
    }

    // not safe to use make sure SessionManager is locked
    fn destroySessionLocked(self: *SessionManager, alloc: std.mem.Allocator, io: std.Io, s: *Session) void {
        for (self.sessions.items, 0..self.sessions.items.len) |session, i| {
            if (s == session) {
                session.deinit(io);
                alloc.destroy(session);
                _ = self.sessions.swapRemove(i);
                break;
            }
        }
    }
};

test "able to find sessions lobby that's not full" {
    var sman = SessionManager.init();
    defer sman.deinit(talloc, tio);

    const a_ptr = try talloc.create(Session);
    a_ptr.* = try Session.init(talloc);
    try sman.sessions.append(talloc, a_ptr);
    const open_session = sman.findOrCreateSession(talloc, tio);

    try t.expectEqual(a_ptr, open_session);
}

test "add new session" {
    var sman = SessionManager.init();
    defer sman.deinit(talloc, tio);

    try sman.addSession(talloc, tio);

    try t.expectEqual(sman.sessions.items.len, 1);
}

test "remove new session" {
    var sman = SessionManager.init();
    defer sman.deinit(talloc, tio);

    try sman.addSession(talloc, tio);
    const s = sman.sessions.items[0];
    sman.destroySessionLocked(talloc, tio, s);

    try t.expectEqual(sman.sessions.items.len, 0);
}

pub const Session = struct {
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex,
    run_group: std.Io.Group,
    game: games.TronGame,
    players: std.ArrayList(*Player),
    queue: MessageQueue,
    count: u64 = 0,
    max_players: u8 = 5,

    const SessionError = error{
        LockedMutex,
        LobbyFull,
    };

    pub fn init(alloc: std.mem.Allocator) !Session {
        const mutex = std.Io.Mutex.init;

        const game = try games.TronGame.init(alloc, games.Spawn.init());
        const players: std.ArrayList(*Player) = .empty;
        const queue = MessageQueue.init(alloc, 64);

        return .{
            .alloc = alloc,
            .mutex = mutex,
            .run_group = .init,
            .game = game,
            .players = players,
            .queue = queue,
        };
    }

    pub fn deinit(self: *Session, io: std.Io) void {
        self.run_group.cancel(io);
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

    pub fn addPlayer(self: *Session, alloc: std.mem.Allocator, io: std.Io) !usize {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.addPlayerLocked(alloc);
    }

    pub fn addPlayerLocked(self: *Session, alloc: std.mem.Allocator) !usize {
        if (self.isFullLocked()) return SessionError.LobbyFull;

        const player = try alloc.create(Player);
        errdefer alloc.destroy(player);
        player.* = Player.init;
        player.outbound = std.Io.Queue(OutboundMsg).init(&player.outbound_buf);

        // replace first disconnected player with new player
        for (self.players.items, 0..) |existing, i| {
            if (existing.status != .disconnected) continue;
            player.idx = i;
            self.players.items[i] = player;
            return i;
        }

        player.idx = self.players.items.len;
        try self.players.append(alloc, player);
        return player.idx;
    }

    pub fn removePlayer(self: *Session, io: std.Io, players_idx: usize) SessionError!void {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.removePlayerLocked(players_idx);
    }

    pub fn removePlayerLocked(self: *Session, players_idx: usize) void {
        self.players.items[players_idx].status = .disconnected;
    }

    pub fn isFull(self: *Session, io: std.Io) SessionError!bool {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.isFullLocked();
    }

    pub fn isFullLocked(self: *Session) bool {
        if (self.players.items.len != self.max_players) return false;
        for (self.players.items) |player| {
            if (player.status != .connected) return false;
        }
        return true;
    }

    pub fn startGame(self: *Session, io: std.Io) !void {
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
            var buf: [20]u8 = undefined;
            const payload = self.game.encodeDeltas(&buf);
            try self.broadcast(io, payload[0..], .binary);
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

        self.broadcast(io, msg[0..], .text) catch |err| std.log.err("{}", .{err});
    }

    pub fn broadcast(self: *Session, io: std.Io, msg: []const u8, op: std.http.Server.WebSocket.Opcode) !void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        try self.broadcastLocked(io, msg, op);
    }

    // This method only just pushes a message to each players queue doesn't actually broadcasts
    pub fn broadcastLocked(self: *Session, io: std.Io, msg: []const u8, op: std.http.Server.WebSocket.Opcode) !void {
        if (msg.len > OutboundMsg.max_frame_size) return error.MessageTooLarge;
        for (self.players.items) |player| {
            var outbound: OutboundMsg = .{
                .data = undefined,
                .len = msg.len,
                .op = op,
            };
            @memcpy(outbound.data[0..outbound.len], msg);
            const queued = try player.outbound.put(io, &.{outbound}, 0);
            if (queued == 0) {
                var dropped: [1]OutboundMsg = undefined;
                _ = try player.outbound.get(io, &dropped, 0);
                std.debug.assert(try player.outbound.put(io, &.{outbound}, 0) == 1);
            }
        }
    }

    pub fn endGame(self: *Session) void {
        self.game.state = .over;
    }

    pub fn startLobby(self: *Session, io: std.Io, countdown: usize) !void {
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

    pub fn canRemove(self: *Session, io: std.Io) SessionError!bool {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.hasNoPlayersLocked();
    }

    pub fn hasNoPlayers(self: *Session, io: std.Io) !bool {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        return self.hasNoPlayersLocked();
    }

    fn hasNoPlayersLocked(self: *Session) bool {
        if (self.players.items.len == 0) return true;
        for (self.players.items) |player| {
            if (player.status == .connected) return false;
        }
        return true;
    }
};

pub const OutboundMsg = struct {
    data: [max_frame_size]u8,
    len: usize,
    op: std.http.Server.WebSocket.Opcode,

    const max_frame_size: usize = 64;
};

test "enqueue a msg for a player in a sesison" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addPlayer(tio);

    try s.broadcast(tio, "{{ \"countdown\": 1 }}", .text);

    const actual = try s.players[0].?.outbound.getOne(tio);
    const expected_text = "{{ \"countdown\": 1 }}";
    const expected_op: std.http.Server.WebSocket.Opcode = .text;

    try t.expectEqualStrings(expected_text, actual.data[0..actual.len]);
    try t.expectEqual(expected_op, actual.op);
    try t.expectEqual(20, actual.len);
}

test "two msg FIFO test" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addPlayer(tio);

    try s.broadcast(tio, "{{ \"countdown\": 2 }}", .text); // first in should be first out
    try s.broadcast(tio, "{{ \"countdown\": 1 }}", .text);

    const first = try s.players[0].?.outbound.getOne(tio);
    const first_expected = "{{ \"countdown\": 2 }}";
    const second = try s.players[0].?.outbound.getOne(tio);
    const second_expected = "{{ \"countdown\": 1 }}";
    try t.expectEqualStrings(first_expected, first.data[0..first.len]);
    try t.expectEqualStrings(second_expected, second.data[0..second.len]);
}

pub const Player = struct {
    idx: usize,
    outbound_buf: [10]OutboundMsg,
    outbound: std.Io.Queue(OutboundMsg),
    status: Status,

    const Status = enum {
        connected,
        disconnected,
        dead,
    };

    const init: Player = .{
        .idx = undefined,
        .outbound_buf = undefined,
        .outbound = undefined,
        .status = .connected,
    };
};

test "boardcast drops the oldest frame for a full player queue" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addPlayer(tio);
    const player = &s.players[0].?;
    const msgs = [_][]const u8{
        "0", "1", "2", "3", "4",  "5",
        "6", "7", "8", "9", "10",
    };
    for (msgs) |msg| {
        try s.broadcast(tio, msg, .text);
    }

    const first = try player.outbound.getOne(tio);
    try t.expectEqualStrings("1", first.data[0..first.len]);
}

// message queue that collects the message from clients that is owned
pub const MessageQueue = struct {
    queue: std.Deque(Message),

    pub const Message = struct {
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
    defer s.deinit(tio);

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
    defer s.deinit(tio);

    try s.queue.push(talloc, .{ .idx = 2, .key_pressed = 107 });
    try s.queue.push(talloc, .{ .idx = 1, .key_pressed = 107 });
    try s.queue.push(talloc, .{ .idx = 4, .key_pressed = 108 });
    try s.drain(tio);

    try t.expectEqual(0, s.queue.len());
}

test "is lobby full" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);

    try t.expect(try s.isFull(tio));
}

test "is lobby full error" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);

    const full_lobby_err = s.addPlayer(tio) catch |err| err;

    try t.expectError(Session.SessionError.LobbyFull, full_lobby_err);
}

test "is lobby full and game switched to running" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);
    _ = try s.addPlayer(tio);

    try s.startLobby(tio, 1);
    try t.expectEqual(s.game.state, games.GameState.running);
}

test "remove player and replace idx with null" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addPlayer(tio);
    try s.removePlayer(tio, 0);

    try t.expect((s.players[0] == null));
}
