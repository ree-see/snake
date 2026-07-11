const std = @import("std");
const session = @import("session.zig");
const ws = @import("websocket.zig");
const http = std.http;
const crypto = std.crypto;
const base64 = std.base64;

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

    pub fn init(io: std.Io, listener: *std.Io.net.Server, alloc: std.mem.Allocator) !Connection {
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

// TODO: refactor args into a context struct
pub fn handleWs(key: []const u8, io: std.Io, r: *std.Io.Reader, w: *std.Io.Writer, s: *session.Session) !void {
    const computed_key = ws.computeAcceptKey(key);
    try w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n", .{&computed_key});
    try w.writeAll("\r\n");
    try w.flush();

    const idx = s.addPlayer(io, w) catch |err| {
        try w.print("{}", .{err});
        try w.flush();
        return err;
    };
    // frame while loop
    while (true) {
        const byte0 = r.takeByte() catch break; // [FIN 1bit][RSV 3bits][opcode 4bits]
        const byte1 = try r.takeByte(); // [MASK 1bit][paylaod-len 7bits]

        const opcode = byte0 & 0x0F; // what kind of frame
        _ = opcode; // will use later
        const is_masked = byte1 & 0x80; // bit 0 1 = is masked 0 = not masked illegal frame
        if (is_masked == 0) {
            continue;
        }
        const length = byte1 & 0x7F; // 7-bit length if 126 -> next 2 bytes if 127 the next 8 bytes
        const masking_key = try r.takeArray(4); // key to unmask the bit in the payload bytes
        const payload = try r.take(length); // payload bytes
        ws.unmaskBits(payload, masking_key.*);
        // try writeFrame(w, payload);
        try s.queue.push(s.alloc, .{ .idx = idx, .key_pressed = payload[0] });
    }
    return;
}

// TODO: refactor args into a method on Connection
pub fn handleConn(conn: *Connection, session_man: *session.SessionManager) !void {
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

        var headers = req.iterateHeaders();
        var key: ?[]const u8 = null;

        var is_upgrade = false;
        while (headers.next()) |next_header| {
            if (std.ascii.eqlIgnoreCase(next_header.name, "upgrade")) {
                is_upgrade = true;
            }
            if (is_upgrade and std.ascii.eqlIgnoreCase(next_header.name, "sec-websocket-key")) {
                key = next_header.value;
            }
        }
        if (key != null) {
            const s = try session_man.findOrCreateSession(conn.alloc, conn.io);
            try handleWs(key.?, conn.io, r, w, s);
            continue;
        }
        try serveFile(&req, conn.io, conn.alloc);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(8080) };
    var listener = try std.Io.net.IpAddress.listen(&addr, io, .{});
    const gpa = init.gpa;
    var sman = session.SessionManager.init();
    defer sman.deinit(gpa);

    while (true) {
        const conn = try gpa.create(Connection);
        conn.* = Connection.init(io, &listener, gpa) catch |err| {
            std.debug.print("{}", .{err});
            continue;
        };
        const thread = std.Thread.spawn(.{}, handleConn, .{ conn, &sman }) catch |err| {
            std.debug.print("{}", .{err});
            continue;
        };
        thread.detach();
    }
}

pub fn serveFile(req: *http.Server.Request, io: std.Io, alloc: std.mem.Allocator) !void {
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
    const body = std.Io.Dir.cwd().readFileAlloc(io, file_path, alloc, .limited(10 * 1024 * 1024)) catch {
        try req.respond("", .{ .status = .not_found });
        return;
    };
    defer alloc.free(body);

    try req.respond(body, .{
        .extra_headers = &.{.{ .name = "content-type", .value = mime }},
    });
}
