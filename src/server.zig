const std = @import("std");
const session = @import("session");
const core = @import("core");

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
    try s.pushMessage(
        io,
        .{ .idx = idx, .direction = try core.dirFromKeyPress(msg.data[0]) },
    );
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
    var input = [_]u8{ 0x81, 0x81, 0, 0, 0, 0, 'k' };
    var r = std.Io.Reader.fixed(&input);
    var ws: std.http.Server.WebSocket = .{
        .key = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        .input = &r,
        .output = &w,
    };
    try readOneInbound(&s, tio, &ws, 0);

    const expected = session.MessageQueue.Message{ .idx = 0, .direction = .down };
    const actual = try s.popMessage(tio);

    try t.expectEqual(expected, actual);
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
