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
            try handleWebSocket(key.?, r, w);
            continue;
        }
        try serveFile(&req, io, gpa);
    }
}

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

test "websocket protocol key test" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const result = computeAcceptKey(key);

    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &result);
}

pub fn unmaskBits(payload: []u8, key: [4]u8) void {
    for (payload, 0..) |*byte, i| {
        byte.* ^= key[i % 4];
    }
}

test "payload bit unmasking" {
    var payload = [_]u8{ 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    const key: [4]u8 = .{ 0x37, 0xfa, 0x21, 0x3d };

    unmaskBits(&payload, key);

    try std.testing.expectEqualStrings("Hello", &payload);
}

pub fn writeFrame(w: *std.Io.Writer, payload: []const u8) !void {
    try w.writeByte(0x81);
    try w.writeByte(@intCast(payload.len));
    try w.writeAll(payload);
    try w.flush();
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

pub fn handleWebSocket(key: []const u8, r: *std.Io.Reader, w: *std.Io.Writer) !void {
    const computed_key = computeAcceptKey(key);
    try w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n", .{&computed_key});
    try w.writeAll("\r\n");
    try w.flush();

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
        unmaskBits(payload, masking_key.*);
        try writeFrame(w, payload);
    }
    return;
}
