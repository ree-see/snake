const std = @import("std");
const json = std.json;
const session = @import("session");
const core = @import("core");
const games = @import("games");

const http = std.http;
const crypto = std.crypto;
const base64 = std.base64;

const t = std.testing;
const talloc = t.allocator;
const tio = t.io;

const MIME_MAP = std.StaticStringMap([]const u8).initComptime(.{
    .{ ".html", "text/html" },
    .{ ".css", "text/css" },
    .{ ".wasm", "application/wasm" },
    .{ ".js", "text/js" },
});

const Connection = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    alloc: std.mem.Allocator,

    pub fn init(
        io: std.Io,
        listener: *std.Io.net.Server,
        alloc: std.mem.Allocator,
    ) !Connection {
        const stream = try listener.accept(io);
        return .{
            .io = io,
            .stream = stream,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.io);
        self.alloc.destroy(self);
    }
};

fn writeOneOutbound(
    io: std.Io,
    ws: *std.http.Server.WebSocket,
    outbound: *std.Io.Queue(session.OutboundMsg),
) !void {
    const outbound_msg = try outbound.getOne(io);
    try ws.writeMessage(outbound_msg.data[0..outbound_msg.len], outbound_msg.op);
}

fn readOneInbound(
    s: *session.Session,
    io: std.Io,
    ws: *std.http.Server.WebSocket,
    idx: usize,
) !void {
    const msg = try ws.readSmallMessage();
    switch (msg.opcode) {
        .binary => {
            // FIXME: need to figure out the best way to handle invalid keypress
            const dir = try core.dirFromKeyPress(msg.data[0]);
            const evmsg: session.EventQueue.Event = .{
                .direction = .{ .idx = idx, .direction = dir },
            };
            try s.pushEvent(io, evmsg);
        },
        .text => {
            const resync_msg = [_]u8{
                '{', '"', 'k', 'i', 'n', 'd', '"', ':',
                '"', 'r', 'e', 's', 'y', 'n', 'c', '"',
                '}',
            };

            if (std.mem.eql(u8, msg.data, &resync_msg)) {
                const evmsg: session.EventQueue.Event = .{ .resync = .{ .idx = idx } };
                try s.pushEvent(io, evmsg);
            }
        },
        else => {},
    }
}

// server > client bytes into ws.output
test "write a queued message to websocket" {
    var s = try session.Session.init(talloc);
    defer s.deinit(tio);
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ws: std.http.Server.WebSocket = .{
        .key = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        .input = undefined,
        .output = &w,
    };

    _ = try s.addClient(talloc, tio);
    const msg = "hi";
    try s.broadcast(tio, msg, .text); // each player receives outbound msg

    const player = s.clients.items[0];
    try writeOneOutbound(tio, &ws, &player.outbound); // first outbound msg is written to ws.output

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x81, 0x02, 'h', 'i' },
        w.buffered(),
    );
}

test "read a ws msg into the session queue" {
    var s = try session.Session.init(talloc);
    defer s.deinit(tio);
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var input = [_]u8{ 0x82, 0x81, 0, 0, 0, 0, 'k' };
    var r = std.Io.Reader.fixed(&input);
    var ws: std.http.Server.WebSocket = .{
        .key = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        .input = &r,
        .output = &w,
    };
    try readOneInbound(&s, tio, &ws, 0);

    const expected = session.EventQueue.Event{
        .direction = .{ .idx = 0, .direction = .down },
    };
    const actual = try s.popEvent(tio);

    try t.expectEqual(expected, actual);
}

test "read a ws resync msg text into the session queue" {
    var s = try session.Session.init(talloc);
    defer s.deinit(tio);
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var input: [25]u8 align(4) = .{
        0x81, 0xfe, 0x00, 0x11, 0,   0,   0,   0,
        '{',  '"',  'k',  'i',  'n', 'd', '"', ':',
        '"',  'r',  'e',  's',  'y', 'n', 'c', '"',
        '}',
    };
    var r = std.Io.Reader.fixed(&input);
    var ws: std.http.Server.WebSocket = .{
        .key = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        .input = &r,
        .output = &w,
    };
    try readOneInbound(&s, tio, &ws, 0);

    const expected = session.EventQueue.Event{
        .resync = .{ .idx = 0 },
    };
    const actual = try s.popEvent(tio);

    try t.expectEqual(expected, actual);
}

test "protocol integration: init, input, and delta frame" {
    var s = try session.Session.init(talloc);
    defer s.deinit(tio);

    const seed: u64 = 0;
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    _ = try s.addClient(talloc, tio);
    try s.startLobby(talloc, tio, rand, 0);

    // Verify init message
    const client = s.clients.items[0];
    const init_raw = try client.outbound.getOne(tio);
    try t.expectEqual(std.http.Server.WebSocket.Opcode.text, init_raw.op);
    const parsed_init = try json.parseFromSlice(
        session.OutboundMsg.InitMessage,
        talloc,
        init_raw.data[0..init_raw.len],
        .{},
    );
    defer parsed_init.deinit();

    try t.expectEqual(session.OutboundMsg.MsgType.init, parsed_init.value.kind);
    try t.expectEqual(s.game.snakes.len, parsed_init.value.snakes.len);

    const s_snakes = s.game.snakes.slice();
    const bodies = s_snakes.items(.body);
    for (bodies, 0..) |body, i| {
        try t.expectEqual(i, parsed_init.value.snakes[i].idx);
        try t.expectEqual(body.items[0].x, parsed_init.value.snakes[i].x);
        try t.expectEqual(body.items[0].y, parsed_init.value.snakes[i].y);
    }

    // Set snake 0 to moving right so we can verify delta movement
    s_snakes.items(.direction)[0] = .right;

    // Send a down keypress through a binary WebSocket frame
    var w_buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&w_buf);
    const keypress = core.keyPressFromDir(.down);
    var input: [7]u8 align(4) = .{ 0x82, 0x81, 0, 0, 0, 0, keypress };
    var r = std.Io.Reader.fixed(&input);
    var ws: std.http.Server.WebSocket = .{
        .key = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        .input = &r,
        .output = &w,
    };
    try readOneInbound(&s, tio, &ws, 0);

    // Tick: drain queue + advance sim + encode frame
    try s.tickAndBroadcast(tio);

    // Read the binary delta frame
    const delta_raw = try client.outbound.getOne(tio);
    try t.expectEqual(std.http.Server.WebSocket.Opcode.binary, delta_raw.op);

    // Verify frame layout: 4-byte sequence + encoded_len bytes per snake
    const expected_len: usize = 4 + s.game.snakes.len * games.Tron.Delta.encoded_len;
    try t.expectEqual(expected_len, delta_raw.len);

    // Verify sequence is 1 (first tick after seq=0)
    const seq = std.mem.readInt(u32, delta_raw.data[0..4], .big);
    try t.expectEqual(@as(u32, 1), seq);

    // Snake 0 was set to .right then changed to .down via keypress,
    // so the next head should be directly below the old head.
    const head = bodies[0].items[0];
    const hdr = delta_raw.data[4];
    try t.expect(hdr & 0x04 != 0); // has_pos
    // Delta layout: [0]=hdr, [1]=killer, [2..3]=x u16 LE, [4..5]=y u16 LE  (relative to delta start)
    const pos_base = 4 + 2; // header + killer
    const dx = delta_raw.data[pos_base] | (@as(u16, delta_raw.data[pos_base + 1]) << 8);
    const dy = delta_raw.data[pos_base + 2] | (@as(u16, delta_raw.data[pos_base + 3]) << 8);
    try t.expectEqual(head.x, dx);
    try t.expectEqual(head.y, dy);
}

test "protocol integration: client resync via session event" {
    var s = try session.Session.init(talloc);
    defer s.deinit(tio);

    const seed: u64 = 0;
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    _ = try s.addClient(talloc, tio);
    try s.startLobby(talloc, tio, rand, 0);

    // Consume init message
    const client = s.clients.items[0];
    _ = try client.outbound.getOne(tio);

    // Tick the game a few times to grow a body
    const s_snakes = s.game.snakes.slice();
    s_snakes.items(.direction)[0] = .right;

    for (0..5) |_| try s.tickAndBroadcast(tio);
    // Consume the binary frames from the queue
    for (0..5) |_| _ = try client.outbound.getOne(tio);

    // Enqueue a .resync event
    try s.pushEvent(tio, .{ .resync = .{ .idx = 0 } });
    try s.drain(tio);

    // Read the snapshot response
    const snapshot_raw = try client.outbound.getOne(tio);
    try t.expectEqual(std.http.Server.WebSocket.Opcode.text, snapshot_raw.op);

    const parsed_snapshot = try json.parseFromSlice(
        session.OutboundMsg.ResyncMessage,
        talloc,
        snapshot_raw.data[0..snapshot_raw.len],
        .{},
    );
    defer parsed_snapshot.deinit();

    try t.expectEqual(session.OutboundMsg.MsgType.resync, parsed_snapshot.value.kind);
    try t.expectEqual(s.game.frame_seq, parsed_snapshot.value.sequence);
    try t.expectEqual(s.game.snakes.len, parsed_snapshot.value.snakes.len);

    // Verify each snapshot snake matches authoritative state
    const bodies = s_snakes.items(.body);
    const is_dead = s_snakes.items(.is_dead);
    for (0..s.game.snakes.len) |i| {
        const got = parsed_snapshot.value.snakes[i];
        try t.expectEqual(i, got.idx);
        try t.expectEqual(is_dead[i], got.is_dead);
        try t.expectEqualSlices(core.Position, bodies[i].items, got.body);
    }
}

fn writeOutboundLoop(
    io: std.Io,
    ws: *std.http.Server.WebSocket,
    outbound: *std.Io.Queue(session.OutboundMsg),
) std.Io.Cancelable!void {
    while (true) {
        writeOneOutbound(io, ws, outbound) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return,
            else => {
                std.log.err("outbond ws writer failed : {}", .{err});
                return;
            },
        };
    }
}

fn handleWs(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: *std.http.Server.WebSocket,
    sman: *session.SessionManager,
    s: *session.Session,
) !void {
    const idx = s.addClient(alloc, io) catch |err| {
        try ws.output.print("{}", .{err});
        try ws.output.flush();
        return err;
    };
    defer sman.removeSession(alloc, io, s) catch |err| {
        std.log.err("failed to remove session: {}", .{err});
    };
    defer s.removeClient(io, idx) catch |err| {
        std.log.err("failed to remove player {}: {}", .{ idx, err });
    };

    var conn_group: std.Io.Group = .init;
    defer conn_group.cancel(io);
    const player = s.clients.items[idx];
    try conn_group.concurrent(
        io,
        writeOutboundLoop,
        .{ io, ws, &player.outbound },
    );

    while (true) {
        try readOneInbound(s, io, ws, idx);
    }

    std.debug.print("Client {} disconnected", .{idx});
    return;
}

fn runConn(
    conn: *Connection,
    session_man: *session.SessionManager,
) std.Io.Cancelable!void {
    handleConn(conn, session_man) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.err("connection failed: {}", .{err});
            return;
        },
    };
}

fn handleConn(conn: *Connection, session_man: *session.SessionManager) !void {
    defer conn.deinit();
    while (true) {
        var w_buf: [256]u8 = undefined;
        var writer = conn.stream.writer(conn.io, &w_buf);
        const w = &writer.interface;

        var r_buf: [4096]u8 = undefined;
        var reader = conn.stream.reader(conn.io, &r_buf);
        const r = &reader.interface;

        var server = http.Server.init(r, w);
        var req = try server.receiveHead();

        switch (req.upgradeRequested()) {
            .websocket => |maybe_key| {
                if (maybe_key) |key| {
                    var ws = req.respondWebSocket(.{ .key = key }) catch |err| {
                        std.log.err("{}", .{err});
                        return;
                    };
                    const s = try session_man.findOrCreateSession(
                        conn.alloc,
                        conn.io,
                    );
                    handleWs(
                        conn.alloc,
                        conn.io,
                        &ws,
                        session_man,
                        s,
                    ) catch |err| {
                        std.log.err("{}", .{err});
                        return;
                    };
                }
            },
            .other => {},
            .none => try serveFile(&req, conn.io, conn.alloc),
        }
    }
}

/// Serves static assets and hosts WebSocket-backed multiplayer sessions on port 8080.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // FIXME: this prolly needs to be switch once hosted somewhere
    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(8080) };
    var listener = try std.Io.net.IpAddress.listen(
        &addr,
        io,
        .{ .reuse_address = true },
    );
    const gpa = init.gpa;
    var sman = session.SessionManager.init();
    defer sman.deinit(gpa, io);

    var conn_group = std.Io.Group.init;
    defer conn_group.cancel(io);

    // accept loop
    while (true) {
        const conn = try gpa.create(Connection);
        conn.* = Connection.init(io, &listener, gpa) catch |err| {
            gpa.destroy(conn);
            std.log.err("{}", .{err});
            continue;
        };
        try conn_group.concurrent(io, runConn, .{ conn, &sman });
    }
}

/// Serves a request from the relative `web/` directory with traversal protection.
pub fn serveFile(
    req: *http.Server.Request,
    io: std.Io,
    alloc: std.mem.Allocator,
) !void {
    var file_path: []u8 = undefined;
    var pbuf: [256]u8 = undefined;

    var target = req.head.target;
    if (std.mem.find(u8, target, "..") != null) {
        try req.respond("", .{ .status = .not_found });
        return;
    }

    if (std.mem.eql(u8, target, "/")) {
        target = "/index.html";
    }

    if (target[0] == '/') {
        file_path = try std.fmt.bufPrint(&pbuf, "web{s}", .{target});
    }

    const ext = std.fs.path.extension(file_path);
    const mime = MIME_MAP.get(ext) orelse "application/octet-stream";
    const body = std.Io.Dir.cwd().readFileAlloc(
        io,
        file_path,
        alloc,
        .limited(10 * 1024 * 1024),
    ) catch {
        try req.respond("", .{ .status = .not_found });
        return;
    };
    defer alloc.free(body);

    try req.respond(
        body,
        .{ .extra_headers = &.{.{ .name = "content-type", .value = mime }} },
    );
}
