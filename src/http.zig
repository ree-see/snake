const std = @import("std");
const http = std.http;
const crypto = std.crypto;
const base64 = std.base64;

const MIME_MAP = std.StaticStringMap([]const u8).initComptime(.{
    .{ ".html", "text/html" },
    .{ ".css", "text/css" },
    .{ ".wasm", "application/wasm" },
    .{ ".js", "text/js" },
});

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub fn computeAcceptKey(key: []const u8) [28]u8 {
    var digest: [20]u8 = undefined;
    var hash = crypto.hash.Sha1.init(.{});
    hash.update(key);
    hash.update(GUID);
    hash.final(&digest);

    var dest: [28]u8 = undefined;
    _ = base64.standard.Encoder.encode(&dest, &digest);
    return dest;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(8080) };
    var listener = try std.Io.net.IpAddress.listen(&addr, io, .{});
    const gpa = init.gpa;

    while (true) {
        const stream = try listener.accept(io);
        defer stream.close(io);

        var w_buf: [256]u8 = undefined;
        var writer = stream.writer(io, &w_buf);
        const w = &writer.interface;

        var r_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &r_buf);
        const r = &reader.interface;

        var server = http.Server.init(r, w);
        var req = try server.receiveHead();
        var target = req.head.target;
        var file_path: []u8 = undefined;
        var pbuf: [256]u8 = undefined;

        var it = req.iterateHeaders();
        var key: ?[]const u8 = null;

        var is_upgrade = false;
        while (it.next()) |next_header| {
            if (std.ascii.eqlIgnoreCase(next_header.name, "upgrade")) {
                is_upgrade = true;
            }
            if (is_upgrade and std.ascii.eqlIgnoreCase(next_header.name, "sec-websocket-key")) {
                key = next_header.value;
            }
        }

        // TODO: respond with an error code if is_upgrade is false
        // TODO: compute key and send an ack message to confirm with the client if is_upgrade true and have is not null
        if (key != null) {
            const computed_key = computeAcceptKey(key.?);
            try w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n", .{&computed_key});
            try w.writeAll("\r\n");
            try w.flush();
            continue;
        }

        if (std.mem.find(u8, target, "..") != null) {
            try req.respond("", .{ .status = .not_found });
            continue;
        }

        if (std.mem.eql(u8, target, "/")) {
            target = "/index.html";
        }

        if (target[0] == '/') {
            file_path = try std.fmt.bufPrint(&pbuf, "web{s}", .{target});
        }

        const ext = std.fs.path.extension(file_path);
        const mime = MIME_MAP.get(ext) orelse "application/octet-stream";
        const body = std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(10 * 1024 * 1024)) catch {
            try req.respond("", .{ .status = .not_found });
            continue;
        };
        defer gpa.free(body);

        try req.respond(body, .{
            .extra_headers = &.{.{ .name = "content-type", .value = mime }},
        });
    }
}

test "websocket protocol key test" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const result = computeAcceptKey(key);

    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &result);
}
