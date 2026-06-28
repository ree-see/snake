const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(8080) };
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    const gpa = init.gpa;

    while (true) {
        const stream = try server.accept(io);
        defer stream.close(io);

        var w_buf: [256]u8 = undefined;
        var writer = stream.writer(io, &w_buf);
        const w = &writer.interface;

        var r_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &r_buf);
        const r = &reader.interface;

        const line = try r.takeDelimiter('\n') orelse continue;
        var req = std.mem.tokenizeScalar(u8, line, ' ');
        _ = req.next() orelse continue;
        var path = req.next() orelse continue;
        var pbuf: [256]u8 = undefined;
        var file_path: []u8 = undefined;

        if (std.mem.find(u8, path, "..") != null) {
            try w.writeAll("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
            try w.flush();
            continue;
        }

        if (std.mem.eql(u8, path, "/")) {
            path = "/index.html";
        }

        if (path[0] == '/') {
            file_path = try std.fmt.bufPrint(&pbuf, "web{s}", .{path});
        }
        const ext = std.fs.path.extension(file_path);
        const mime_map = std.StaticStringMap([]const u8).initComptime(.{
            .{ ".html", "text/html" },
            .{ ".css", "text/css" },
            .{ ".wasm", "application/wasm" },
            .{ ".js", "text/js" },
        });
        const mime = mime_map.get(ext) orelse "application/octet-stream";
        const body = std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(10 * 1024 * 1024)) catch {
            try w.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            try w.flush();
            continue;
        };
        defer gpa.free(body);

        try w.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: {s}\r\n\r\n", .{ body.len, mime });
        try w.writeAll(body);
        try w.flush();
    }
}
