const core = @import("core");
const std = @import("std");
const http = std.http;
const crypto = std.crypto;
const base64 = std.base64;
const Writer = std.Io.Writer;

const t = std.testing;
const tw = std.Io.Writer.Allocating;
const talloc = t.allocator;
const tio = t.io;

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub fn writeFrame(w: *Writer, payload: []const u8, textFrame: bool) !void {
    // 0x82 = FIN + binary opcode. Was 0x81 (text) -- browsers UTF-8-decode
    // text frames, which mangles raw position/header bytes. Binary frames
    // arrive in JS as an ArrayBuffer untouched.
    const opcode: u8 = if (textFrame) 0x81 else 0x82;
    try w.writeByte(opcode);
    try w.writeByte(@intCast(payload.len));
    try w.writeAll(payload);
    try w.flush();
}

test "writeFrame writes a text payload type test" {
    var aw = tw.init(talloc);
    defer aw.deinit();
    const msg = "hi";

    try writeFrame(&aw.writer, msg, true);
    const expected = [_]u8{0x81};
    const actual = aw.writer.buffered();

    try t.expectEqual(expected[0], actual[0]);
}

test "writeFrame writes a bin payload type test" {
    var aw = tw.init(talloc);
    defer aw.deinit();
    const delta = core.Delta{
        .death = .{
            .died = 1,
            .killer = 4,
        },
        .nextPos = .{ .x = 3, .y = 5 },
    };

    try writeFrame(&aw.writer, &delta.encode(), true);
    const expected = [_]u8{0x81};
    const actual = aw.writer.buffered();

    try t.expectEqual(expected[0], actual[0]);
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
