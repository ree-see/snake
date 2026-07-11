const std = @import("std");
const http = std.http;
const crypto = std.crypto;
const base64 = std.base64;

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub fn writeFrame(w: *std.Io.Writer, payload: []const u8) !void {
    try w.writeByte(0x81);
    try w.writeByte(@intCast(payload.len));
    try w.writeAll(payload);
    try w.flush();
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
