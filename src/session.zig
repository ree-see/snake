const std = @import("std");
const json = std.json;

const core = @import("core");
const games = @import("games");
const Bot = @import("bot");

const talloc = std.testing.allocator;
const t = std.testing;
const tio = std.testing.io;

/// Bounded, owned WebSocket frame data queued for one client.
///
/// When a client queue is full, sessions discard its oldest frame to retain recency.
pub const OutboundMsg = struct {
    data: [max_frame_size]u8,
    len: usize,
    op: std.http.Server.WebSocket.Opcode,

    const max_frame_size: usize = 4096;

    pub const MsgType = enum { init, resync };

    pub const InitMessage = struct {
        kind: MsgType,
        snake_idx: usize,
        snakes: []games.Tron.InitialSnapshot,
    };

    pub const ResyncMessage = struct {
        kind: MsgType,
        sequence: u32,
        snakes: []games.Tron.SnakeSnapshot,
    };
};

/// One connected human endpoint and the snake it controls in a session.
pub const Client = struct {
    snake_idx: usize,
    lastFrame: usize,
    status: Status,

    outbound_buf: [10]OutboundMsg,
    outbound: std.Io.Queue(OutboundMsg),

    const Status = enum {
        connected,
        disconnected,
        dead,
    };

    const init: Client = .{
        .snake_idx = undefined,
        .lastFrame = 0,
        .outbound_buf = undefined,
        .outbound = undefined,
        .status = .connected,
    };
};

/// FIFO collection of client direction inputs consumed by the session tick loop.
pub const EventQueue = struct {
    queue: std.Deque(Event),

    pub const Event = union(enum) {
        direction: DirectionEvent,
        resync: ResyncEvent,
    };
    /// A requested direction for the snake identified by `idx`.
    pub const DirectionEvent = struct {
        idx: usize,
        direction: core.Snake.Direction,
    };

    /// A requested authorative snapshot for a client out of sync
    /// text ws opcode
    pub const ResyncEvent = struct {
        idx: usize,
    };

    /// Allocates queue storage for up to `capacity` pending inputs.
    pub fn init(alloc: std.mem.Allocator, capacity: usize) EventQueue {
        const queue = std.Deque(Event).initCapacity(alloc, capacity) catch unreachable;
        return .{ .queue = queue };
    }

    /// Releases queue storage using the allocator supplied to init.
    pub fn deinit(self: *EventQueue, alloc: std.mem.Allocator) void {
        self.queue.deinit(alloc);
    }

    /// Appends an input to the queue without session synchronization.
    ///
    /// Use `Session.pushEvent` when concurrent clients can write.
    pub fn push(
        self: *EventQueue,
        alloc: std.mem.Allocator,
        message: Event,
    ) !void {
        try self.queue.pushBack(alloc, message);
    }

    /// Removes the oldest input without session synchronization.
    ///
    /// Use `Session.popEvent` when concurrent clients can write.
    pub fn pop(self: *EventQueue) ?Event {
        return self.queue.popFront();
    }

    /// Returns the number of pending inputs.
    pub fn len(self: *EventQueue) usize {
        return self.queue.len;
    }
};

/// Owns all active sessions and assigns joining clients to open lobbies.
///
/// Its mutex protects the session list. Individual sessions use separate mutexes.
pub const SessionManager = struct {
    mutex: std.Io.Mutex,
    sessions: std.ArrayList(*Session),

    /// Creates an empty session manager.
    pub fn init() SessionManager {
        const sessions = std.ArrayList(*Session).empty;
        const mutex = std.Io.Mutex.init;

        const sman: SessionManager = .{
            .mutex = mutex,
            .sessions = sessions,
        };
        return sman;
    }

    /// Cancels, deinitializes, and destroys every managed session.
    pub fn deinit(
        self: *SessionManager,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) void {
        for (self.sessions.items) |session| {
            session.deinit(io);
            alloc.destroy(session);
        }
        self.sessions.deinit(alloc);
    }

    /// Runs one session and records unexpected failures as a game-over state.
    pub fn runSession(s: *Session, io: std.Io) std.Io.Cancelable!void {
        s.run(s.alloc, io) catch |err| switch (err) {
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

    /// Returns an open lobby or creates and starts a new session.
    pub fn findOrCreateSession(
        self: *SessionManager,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !*Session {
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

    /// Adds a session while acquiring the manager mutex.
    pub fn addSession(
        self: *SessionManager,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const s_ptr = try alloc.create(Session);
        s_ptr.* = try Session.init(alloc);
        try self.sessions.append(alloc, s_ptr);
    }

    /// Adds a session while the caller holds the manager mutex.
    pub fn addSessionLocked(self: *SessionManager, alloc: std.mem.Allocator) !void {
        const s_ptr = try alloc.create(Session);
        s_ptr.* = try Session.init(alloc);
        try self.sessions.append(alloc, s_ptr);
    }

    /// Removes an empty session while acquiring the manager mutex.
    pub fn removeSession(
        self: *SessionManager,
        alloc: std.mem.Allocator,
        io: std.Io,
        s: *Session,
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.removeSessionLocked(alloc, io, s);
    }

    /// Removes an empty session while the caller holds the manager mutex.
    pub fn removeSessionLocked(
        self: *SessionManager,
        alloc: std.mem.Allocator,
        io: std.Io,
        s: *Session,
    ) !void {
        if (try s.canRemove(io)) self.destroySessionLocked(alloc, io, s);
    }

    // not safe to use make sure SessionManager is locked
    fn destroySessionLocked(
        self: *SessionManager,
        alloc: std.mem.Allocator,
        io: std.Io,
        s: *Session,
    ) void {
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

/// Owns one Tron match, its connected clients, bots, and synchronized input queue.
pub const Session = struct {
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex,
    run_group: std.Io.Group,
    game: games.Tron,

    clients: std.ArrayList(*Client),
    bots: std.ArrayList(Bot),
    queue: EventQueue,

    max_clients: u8 = 5,

    const SessionError = error{
        LockedMutex,
        LobbyFull,
    };

    /// Creates an empty lobby using `alloc` for all owned game state.
    pub fn init(alloc: std.mem.Allocator) !Session {
        const queue = EventQueue.init(alloc, 64);

        return .{
            .alloc = alloc,
            .mutex = .init,
            .run_group = .init,
            .game = .init,
            .clients = .empty,
            .queue = queue,
            .bots = .empty,
        };
    }

    /// Cancels session work and releases clients, bots, queues, and game state.
    pub fn deinit(self: *Session, io: std.Io) void {
        self.run_group.cancel(io);
        self.game.deinit(self.alloc);
        self.queue.deinit(self.alloc);
        for (self.clients.items) |client| {
            self.alloc.destroy(client);
        }
        self.clients.deinit(self.alloc);
        self.bots.deinit(self.alloc);
    }

    /// Reports whether a client may join the lobby while synchronizing access.
    pub fn canJoin(self: *Session, io: std.Io) SessionError!bool {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        self.mutex.unlock(io);
        return self.canJoinLocked();
    }

    /// Reports whether a client may join while the session mutex is held.
    pub fn canJoinLocked(self: *Session) bool {
        return self.game.state == .lobby and !self.isFullLocked();
    }

    /// Applies every queued direction input while synchronizing access.
    pub fn drain(self: *Session, io: std.Io) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        return try self.drainLocked(io);
    }

    /// Applies every queued direction input while the session mutex is held.
    pub fn drainLocked(self: *Session, io: std.Io) !void {
        while (true) {
            const ev = self.queue.pop() orelse break;
            switch (ev) {
                .direction => |m| {
                    const s = self.game.snakes.slice();
                    const curr_dir = s.items(.direction)[m.idx];
                    s.items(.direction)[m.idx] = core.setDirection(
                        curr_dir,
                        m.direction,
                    );
                },
                .resync => |m| {
                    const snakes = try games.Tron.SnakeSnapshot.fromTron(
                        self.alloc,
                        &self.game,
                    );
                    defer self.alloc.free(snakes);
                    const init_msg: OutboundMsg.ResyncMessage = .{
                        .kind = .resync,
                        .sequence = self.game.frame_seq,
                        .snakes = snakes,
                    };
                    var outbound: OutboundMsg = .{
                        .data = undefined,
                        .len = 0,
                        .op = .text,
                    };
                    var w = std.Io.Writer.fixed(&outbound.data);
                    try json.Stringify.value(
                        init_msg,
                        .{ .whitespace = .minified },
                        &w,
                    );
                    outbound.len = w.buffered().len;
                    try enqueueOutbound(io, self.clients.items[m.idx], outbound);
                },
            }
        }
    }

    /// Adds a connected client and returns its assigned snake index.
    pub fn addClient(self: *Session, alloc: std.mem.Allocator, io: std.Io) !usize {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.addClientLocked(alloc);
    }

    /// Adds a client while the session mutex is held.
    pub fn addClientLocked(self: *Session, alloc: std.mem.Allocator) !usize {
        if (self.isFullLocked()) return SessionError.LobbyFull;

        const client = try alloc.create(Client);
        errdefer alloc.destroy(client);
        client.* = Client.init;
        client.outbound = std.Io.Queue(OutboundMsg).init(&client.outbound_buf);

        // replace first disconnected client with new client
        for (self.clients.items, 0..) |existing, i| {
            if (existing.status != .disconnected) continue;
            client.snake_idx = i;
            self.clients.items[i] = client;
            return i;
        }

        client.snake_idx = self.clients.items.len;
        try self.clients.append(alloc, client);
        return client.snake_idx;
    }

    /// Marks a client disconnected while synchronizing access.
    pub fn removeClient(
        self: *Session,
        io: std.Io,
        clients_idx: usize,
    ) SessionError!void {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.removeClientLocked(clients_idx);
    }

    /// Marks a client disconnected while the session mutex is held.
    pub fn removeClientLocked(self: *Session, clients_idx: usize) void {
        self.clients.items[clients_idx].status = .disconnected;
    }

    /// Reports whether every match slot has a connected client.
    pub fn isFull(self: *Session, io: std.Io) SessionError!bool {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.isFullLocked();
    }

    /// Reports whether every match slot has a connected client while locked.
    pub fn isFullLocked(self: *Session) bool {
        if (self.clients.items.len != self.max_clients) return false;
        for (self.clients.items) |client| {
            if (client.status != .connected) return false;
        }
        return true;
    }

    /// Runs the authoritative tick loop until the Tron match ends.
    pub fn startGame(self: *Session, io: std.Io) !void {
        self.game.state = .running;
        var dead_count: u4 = 0;
        var winner_idx: u8 = undefined;

        const s = self.game.snakes.slice();
        const dead = s.items(.is_dead);
        while (self.game.state != .over) {
            dead_count = 0;

            try self.tickAndBroadcast(io);
            // get each bots decision and enqueue them in self.queue
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

    pub fn tickAndBroadcast(self: *Session, io: std.Io) !void {
        try self.drain(io);
        self.game.tick(self.alloc) catch |err| {
            std.debug.print("{}", .{err});
            self.endGame();
        };
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), std.Io.Clock.awake) catch return;

        // broadcast next render frame
        var buf: [256]u8 = undefined;
        const payload = self.game.encodeDeltas(&buf);
        try self.broadcast(io, payload[0..], .binary);
    }

    /// Queues an identical WebSocket frame for every client while synchronizing access.
    pub fn broadcast(
        self: *Session,
        io: std.Io,
        msg: []const u8,
        op: std.http.Server.WebSocket.Opcode,
    ) !void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        try self.broadcastLocked(io, msg, op);
    }

    /// Queues an identical frame for every client while the session mutex is held.
    ///
    /// Connection writer loops perform the actual WebSocket writes.
    pub fn broadcastLocked(
        self: *Session,
        io: std.Io,
        msg: []const u8,
        op: std.http.Server.WebSocket.Opcode,
    ) !void {
        if (msg.len > OutboundMsg.max_frame_size) return error.EventTooLarge;
        for (self.clients.items) |client| {
            var outbound: OutboundMsg = .{
                .data = undefined,
                .len = msg.len,
                .op = op,
            };
            @memcpy(outbound.data[0..outbound.len], msg);
            try enqueueOutbound(io, client, outbound);
        }
    }

    fn enqueueOutbound(io: std.Io, client: *Client, outbound: OutboundMsg) !void {
        const queued = try client.outbound.put(io, &.{outbound}, 0);
        if (queued != 0) return;

        var dropped: [1]OutboundMsg = undefined;
        _ = try client.outbound.get(io, &dropped, 0);
        std.debug.assert(try client.outbound.put(io, &.{outbound}, 0) == 1);
    }

    /// Stops the current game loop on its next state check.
    pub fn endGame(self: *Session) void {
        self.game.state = .over;
    }

    /// Waits for a client, runs the countdown, fills bot slots, and initializes the match.
    ///
    /// Each connected client receives a personalized JSON snapshot before running begins.
    pub fn startLobby(
        self: *Session,
        alloc: std.mem.Allocator,
        io: std.Io,
        rand: std.Random,
        countdown: usize,
    ) !void {
        while (self.clients.items.len == 0) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), std.Io.Clock.awake) catch return;
        } else {
            for (1..countdown + 1) |i| {
                std.Io.sleep(io, std.Io.Duration.fromSeconds(1), std.Io.Clock.awake) catch return;
                var buf: [20]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{{ \"countdown\": {d} }}", .{countdown + 1 - i}) catch unreachable;
                try self.broadcast(io, msg, .text);
            }

            if (self.clients.items.len <= self.max_clients) try self.fillBots(io, self.max_clients - self.clients.items.len);
            for (0..self.max_clients) |_| {
                try self.game.spawnSnake(alloc, rand);
            }

            const snapshot = try games.Tron.InitialSnapshot.fromTron(alloc, &self.game);
            defer alloc.free(snapshot);

            for (self.clients.items) |client| {
                if (client.status != .connected) continue;

                const init_msg: OutboundMsg.InitMessage = .{
                    .kind = .init,
                    .snake_idx = client.snake_idx,
                    .snakes = snapshot,
                };
                var outbound: OutboundMsg = .{
                    .data = undefined,
                    .len = 0,
                    .op = .text,
                };
                var w = std.Io.Writer.fixed(&outbound.data);
                try json.Stringify.value(
                    init_msg,
                    .{ .whitespace = .minified },
                    &w,
                );
                outbound.len = w.buffered().len;

                try enqueueOutbound(io, client, outbound);
            }

            self.game.state = .running;
        }
    }

    /// Seeds and runs the lobby phase followed by the game phase.
    pub fn run(self: *Session, alloc: std.mem.Allocator, io: std.Io) !void {
        const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        try self.startLobby(alloc, io, rand, 20);
        try self.startGame(io);
    }

    /// Appends bots for unoccupied match slots while synchronizing access.
    pub fn fillBots(self: *Session, io: std.Io, n_bots: usize) SessionError!void {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        try self.fillBotsLocked(n_bots);
    }

    /// Appends bots for unoccupied match slots while the session mutex is held.
    pub fn fillBotsLocked(self: *Session, n_bots: usize) !void {
        for (self.clients.items.len..n_bots + self.clients.items.len) |i| {
            self.bots.append(self.alloc, .{ .snake_idx = i }) catch @panic("OOM error");
        }
    }

    /// Enqueues a client direction input while synchronizing access.
    pub fn pushEvent(
        self: *Session,
        io: std.Io,
        msg: EventQueue.Event,
    ) SessionError!void {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        self.queue.push(self.alloc, msg) catch @panic("OOM error");
    }

    /// Removes the oldest client direction input while synchronizing access.
    pub fn popEvent(self: *Session, io: std.Io) SessionError!?EventQueue.Event {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.queue.pop();
    }

    /// Reports whether every client has disconnected and the session can be removed.
    pub fn canRemove(self: *Session, io: std.Io) SessionError!bool {
        self.mutex.lock(io) catch return SessionError.LockedMutex;
        defer self.mutex.unlock(io);
        return self.hasNoClientsLocked();
    }

    /// Reports whether no connected clients remain.
    pub fn hasNoClients(self: *Session, io: std.Io) !bool {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        return self.hasNoClientsLocked();
    }

    fn hasNoClientsLocked(self: *Session) bool {
        if (self.clients.items.len == 0) return true;
        for (self.clients.items) |client| {
            if (client.status == .connected) return false;
        }
        return true;
    }

    /// Queues one selected direction for every live bot.
    pub fn enqueueBotDecisions(self: *Session, io: std.Io) !void {
        for (self.bots.items) |*bot| {
            const dir = bot.decide(&self.game) orelse continue;
            const msg: EventQueue.Event = .{
                .direction = .{ .idx = bot.snake_idx, .direction = dir },
            };
            try self.pushEvent(io, msg);
        }
    }
};

test "enqueue a msg for a client in a sesison" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addClient(talloc, tio);

    try s.broadcast(tio, "{{ \"countdown\": 1 }}", .text);

    const actual = try s.clients.items[0].outbound.getOne(tio);
    const expected_text = "{{ \"countdown\": 1 }}";
    const expected_op: std.http.Server.WebSocket.Opcode = .text;

    try t.expectEqualStrings(expected_text, actual.data[0..actual.len]);
    try t.expectEqual(expected_op, actual.op);
    try t.expectEqual(20, actual.len);
}

test "two msg FIFO test" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addClient(talloc, tio);

    // first in should be first out
    try s.broadcast(tio, "{{ \"countdown\": 2 }}", .text);
    try s.broadcast(tio, "{{ \"countdown\": 1 }}", .text);

    const first = try s.clients.items[0].outbound.getOne(tio);
    const first_expected = "{{ \"countdown\": 2 }}";
    const second = try s.clients.items[0].outbound.getOne(tio);
    const second_expected = "{{ \"countdown\": 1 }}";
    try t.expectEqualStrings(first_expected, first.data[0..first.len]);
    try t.expectEqualStrings(second_expected, second.data[0..second.len]);
}

test "lobby fills remaining slots with bots" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    _ = try s.addClient(talloc, tio);

    try s.startLobby(talloc, tio, rand, 1);

    try t.expectEqual(5, s.game.snakes.len);
    try t.expectEqual(1, s.clients.items.len);
    try t.expectEqual(4, s.bots.items.len);
    try t.expectEqual(0, s.clients.items[0].snake_idx);
    for (0..s.bots.items.len) |i| {
        try t.expectEqual(i + 1, s.bots.items[i].snake_idx);
    }
}

test "session able to fill inputs from bots" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    _ = try s.addClient(talloc, tio);
    try s.startLobby(talloc, tio, rand, 1);

    try s.enqueueBotDecisions(tio);

    try t.expectEqual(4, s.queue.len());

    for (0..s.bots.items.len) |i| {
        const bot_msg = try s.popEvent(tio);
        try t.expectEqual(i + 1, bot_msg.?.direction.idx);
    }
}

test "boardcast drops the oldest frame for a full client queue" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addClient(talloc, tio);
    const client = s.clients.items[0];
    const msgs = [_][]const u8{
        "0", "1", "2", "3", "4",  "5",
        "6", "7", "8", "9", "10",
    };
    for (msgs) |msg| {
        try s.broadcast(tio, msg, .text);
    }

    const first = try client.outbound.getOne(tio);
    try t.expectEqualStrings("1", first.data[0..first.len]);
}

test "drain changes the direction of snakes" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    try s.game.spawnSnake(talloc, rand);
    try s.game.spawnSnake(talloc, rand);
    try s.game.spawnSnake(talloc, rand);
    try s.game.spawnSnake(talloc, rand);
    try s.game.spawnSnake(talloc, rand);

    const snakes = s.game.snakes.slice();
    const dirs = snakes.items(.direction);
    const curr_dirs2 = dirs[2];
    const curr_dirs1 = dirs[1];
    const curr_dirs4 = dirs[4];
    dirs[2] = core.setDirection(curr_dirs2, .left);
    dirs[1] = core.setDirection(curr_dirs1, .up);
    dirs[4] = core.setDirection(curr_dirs4, .left);

    try s.queue.push(talloc, .{ .direction = .{ .idx = 2, .direction = .down } });
    try s.queue.push(talloc, .{ .direction = .{ .idx = 1, .direction = .left } });
    try s.queue.push(talloc, .{ .direction = .{ .idx = 4, .direction = .down } });
    try s.drain(tio);

    try t.expectEqual(.down, snakes.items(.direction)[2]);
    try t.expectEqual(.left, snakes.items(.direction)[1]);
    try t.expectEqual(.down, snakes.items(.direction)[4]);
}

test "pop message off of queue" {
    var queue = EventQueue.init(talloc, 8);
    defer queue.deinit(talloc);

    try queue.push(talloc, .{ .direction = .{ .idx = 2, .direction = .down } });
    try queue.push(talloc, .{ .direction = .{ .idx = 1, .direction = .down } });
    try queue.push(talloc, .{ .direction = .{ .idx = 4, .direction = .right } });

    try t.expectEqual(2, queue.pop().?.direction.idx);
}

test "push message to queue" {
    var queue = EventQueue.init(talloc, 8);
    defer queue.deinit(talloc);

    try queue.push(talloc, .{ .direction = .{ .idx = 2, .direction = .down } }); // 1
    try queue.push(talloc, .{ .direction = .{ .idx = 1, .direction = .down } }); // 2
    try queue.push(talloc, .{ .direction = .{ .idx = 4, .direction = .right } }); // 3

    try t.expectEqual(3, queue.len());
}

test "drain messages in queue" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    try s.game.spawnSnake(talloc, rand);
    try s.game.spawnSnake(talloc, rand);
    try s.game.spawnSnake(talloc, rand);
    try s.game.spawnSnake(talloc, rand);
    try s.game.spawnSnake(talloc, rand);

    try s.queue.push(talloc, .{ .direction = .{ .idx = 2, .direction = .down } });
    try s.queue.push(talloc, .{ .direction = .{ .idx = 1, .direction = .down } });
    try s.queue.push(talloc, .{ .direction = .{ .idx = 4, .direction = .right } });
    try s.drain(tio);

    try t.expectEqual(0, s.queue.len());
}

test "is lobby full" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);

    try t.expect(try s.isFull(tio));
}

test "is lobby full error" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);

    const full_lobby_err = s.addClient(talloc, tio) catch |err| err;

    try t.expectError(Session.SessionError.LobbyFull, full_lobby_err);
}

test "is lobby full and game switched to running" {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(tio).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);
    _ = try s.addClient(talloc, tio);

    try s.startLobby(talloc, tio, rand, 1);
    try t.expectEqual(s.game.state, games.GameState.running);
}

test "remove client and replace idx with null" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    const client_idx = try s.addClient(talloc, tio);
    try s.removeClient(tio, client_idx);

    try t.expectEqual(
        Client.Status.disconnected,
        s.clients.items[client_idx].status,
    );
}

test "initialization is personalized delivery, not a broadcast" {
    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    const snake_idx = try s.addClient(talloc, tio);
    try s.startLobby(talloc, tio, rand, 0);

    var received: [1]OutboundMsg = undefined;
    const queued_frame = try s.clients.items[snake_idx].outbound.get(
        tio,
        &received,
        0,
    );
    try t.expect(queued_frame == 1);
    const init_msg = received[0];
    const data = init_msg.data[0..init_msg.len];
    const parsed_data = try json.parseFromSlice(
        OutboundMsg.InitMessage,
        talloc,
        data,
        .{},
    );
    defer parsed_data.deinit();

    try t.expectEqual(OutboundMsg.MsgType.init, parsed_data.value.kind);
    try t.expectEqual(snake_idx, parsed_data.value.snake_idx);
    try t.expectEqual(s.game.snakes.len, parsed_data.value.snakes.len);

    const snakes = s.game.snakes.slice();
    const bodies = snakes.items(.body);
    for (bodies, 0..) |body, i| {
        const head = body.items[0];
        try t.expect(parsed_data.value.snakes[i].idx == i);
        try t.expectEqual(head.x, parsed_data.value.snakes[i].x);
        try t.expectEqual(head.y, parsed_data.value.snakes[i].y);
    }

    try t.expectEqual(std.http.Server.WebSocket.Opcode.text, init_msg.op);
}

fn applyClientFrame(
    body: *std.ArrayList(core.Position),
    frame: OutboundMsg,
    alloc: std.mem.Allocator,
) !void {
    if (frame.op != .binary or frame.data[4] & 0x04 == 0) return;
    try body.insert(alloc, 0, .{
        .x = frame.data[6],
        .y = frame.data[7],
    });
}

test "client resynchronizes after an outbound frame is dropped" {
    var s = try Session.init(talloc);
    defer s.deinit(tio);

    _ = try s.addClient(talloc, tio);
    try s.game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 10, .y = 10 }, .right),
    );
    try s.game.snakes.append(
        talloc,
        try core.Snake.initAt(talloc, .{ .x = 10, .y = 20 }, .right),
    );

    const client = s.clients.items[0];
    var client_body = std.ArrayList(core.Position).empty;
    defer client_body.deinit(talloc);
    try client_body.append(talloc, .{ .x = 10, .y = 10 });

    // The client receives the first three frames normally.
    for (0..3) |_| {
        try s.tickAndBroadcast(tio);
        try applyClientFrame(&client_body, try client.outbound.getOne(tio), talloc);
    }

    // Simulate a slow connection: twelve frames arrive while the client reads none.
    for (0..12) |_| try s.tickAndBroadcast(tio);

    var pending: [s.clients.items[0].outbound_buf.len]OutboundMsg = undefined;
    const n = try client.outbound.get(tio, &pending, 0);
    try t.expectEqual(@as(usize, 10), n);

    for (pending[0..n]) |frame| try applyClientFrame(&client_body, frame, talloc);

    const authoritative_body = s.game.snakes.items(.body)[0].items;
    try t.expect(authoritative_body.len != client_body.items.len);

    try s.pushEvent(tio, .{ .resync = .{ .idx = 0 } });
    try s.drain(tio);

    const snapshot_msg = try client.outbound.getOne(tio);
    try t.expectEqual(std.http.Server.WebSocket.Opcode.text, snapshot_msg.op);
    const parsed_snapshot = try json.parseFromSlice(
        OutboundMsg.ResyncMessage,
        talloc,
        snapshot_msg.data[0..snapshot_msg.len],
        .{},
    );
    defer parsed_snapshot.deinit();

    try t.expectEqual(OutboundMsg.MsgType.resync, parsed_snapshot.value.kind);
    try t.expectEqual(s.game.frame_seq, parsed_snapshot.value.sequence);
    try t.expectEqualSlices(
        core.Position,
        authoritative_body,
        parsed_snapshot.value.snakes[0].body,
    );
}

test "finds a lobby that is not full" {
    var manager = SessionManager.init();
    defer manager.deinit(talloc, tio);

    const session_ptr = try talloc.create(Session);
    session_ptr.* = try Session.init(talloc);
    try manager.sessions.append(talloc, session_ptr);

    const open_session = try manager.findOrCreateSession(talloc, tio);
    try t.expectEqual(session_ptr, open_session);
}

test "adds a session" {
    var manager = SessionManager.init();
    defer manager.deinit(talloc, tio);

    try manager.addSession(talloc, tio);
    try t.expectEqual(1, manager.sessions.items.len);
}

test "removes an empty session" {
    var manager = SessionManager.init();
    defer manager.deinit(talloc, tio);

    try manager.addSession(talloc, tio);
    const session_ptr = manager.sessions.items[0];
    manager.destroySessionLocked(talloc, tio, session_ptr);

    try t.expectEqual(0, manager.sessions.items.len);
}
