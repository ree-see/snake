const std = @import("std");
const session = @import("session");
// const ws = @import("websocket");
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

// TODO: refactor function
fn handleWs(io: std.Io, ws: *std.http.Server.WebSocket, s: *session.Session) !void {
    const idx = s.addPlayer(io, ws) catch |err| {
        try ws.output.print("{}", .{err});
        try ws.output.flush();
        return err;
    };

    while (true) {
        const small_message = ws.readSmallMessage() catch break;
        try ws.writeMessage(small_message.data, small_message.opcode);
        s.pushMessage(io, .{ .idx = idx, .key_pressed = small_message.data[0] }) catch |err| {
            std.log.err("{}", .{err});
        };
    }

    s.removePlayer(io, idx) catch |err| {
        std.log.err("{}", .{err});
    };
    std.debug.print("Player {} disconnected", .{idx});
    return;
}

pub fn handleConn(conn: *Connection, session_man: *session.SessionManager) !void {
    defer {
        conn.deinit();
    }
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
                    const s = try session_man.findOrCreateSession(conn.alloc, conn.io);
                    handleWs(conn.io, &ws, s) catch |err| {
                        std.log.err("{}", .{err});
                        return;
                    };
                }
            },
            .other => {},
            .none => try serveFile(&req, conn.io, conn.alloc),
        }

        // var headers = req.iterateHeaders();
        // var key: ?[]const u8 = null;

        // var is_upgrade = false;
        // while (headers.next()) |next_header| {
        //     std.debug.print("header: {s} = {s}\n", .{ next_header.name, next_header.value });
        //     if (std.ascii.eqlIgnoreCase(next_header.name, "upgrade")) {
        //         is_upgrade = true;
        //     }
        //     if (is_upgrade and std.ascii.eqlIgnoreCase(next_header.name, "sec-websocket-key")) {
        //         key = next_header.value;
        //     }
        // }
        // if (key != null) {
        //     const s = try session_man.findOrCreateSession(conn.alloc, conn.io);
        //     handleWs(key.?, conn.io, r, w, s) catch |err| {
        //         std.debug.print("handleWs error: {}\n", .{err});
        //         return err;
        //     };
        //     continue;
        // }
        // try serveFile(&req, conn.io, conn.alloc);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(8080) };
    var listener = try std.Io.net.IpAddress.listen(&addr, io, .{
        .reuse_address = true,
    });
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
