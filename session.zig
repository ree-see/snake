const std = @import("std");
const core = @import("core");

const Session = struct {
    game: core.TronGame,
    queue: MessageQueue,
};

// message queue that collects the message from clients that is owned
const MessageQueue = struct {
    queue: std.Deque(Message),

    const Message = struct {
        idx: usize,
        key_pressed: u8,
    };

    pub fn init(alloc: std.mem.Allocator, capacity: usize) MessageQueue {
        const queue = std.Deque(Message).initCapacity(alloc, capacity) catch unreachable;
        return .{ .queue = queue };
    }

    pub fn deinit(self: *MessageQueue, alloc: std.mem.Allocator) void {
        self.queue.deinit(alloc);
    }

    // add new message to the back of the queue
    pub fn push(self: *MessageQueue, alloc: std.mem.Allocator, message: Message) !void {
        try self.queue.pushBack(alloc, message);
    }

    // remove the message at the front of the queue
    pub fn pop(self: *MessageQueue) ?Message {
        return self.queue.popFront();
    }

    pub fn drain(self: *MessageQueue) void {
        while (self.queue.len != 0) {
            _ = self.pop();
        }
    }

    pub fn len(self: *MessageQueue) usize {
        return self.queue.len;
    }
};

const test_gpa = std.testing.allocator;
const t = std.testing;

test "pop message off of queue" {
    var queue = MessageQueue.init(test_gpa, 8);
    defer queue.deinit(test_gpa);
    try queue.push(test_gpa, .{ .idx = 2, .key_pressed = 107 });
    try queue.push(test_gpa, .{ .idx = 1, .key_pressed = 107 });
    try queue.push(test_gpa, .{ .idx = 4, .key_pressed = 108 });

    try t.expectEqual(2, queue.pop().?.idx);
}

test "push message to queue" {
    var queue = MessageQueue.init(test_gpa, 8);
    defer queue.deinit(test_gpa);
    try queue.push(test_gpa, .{ .idx = 2, .key_pressed = 107 }); // 1
    try queue.push(test_gpa, .{ .idx = 1, .key_pressed = 107 }); // 2
    try queue.push(test_gpa, .{ .idx = 4, .key_pressed = 108 }); // 3

    try t.expectEqual(3, queue.len());
}

test "drain messages in queue" {
    var queue = MessageQueue.init(test_gpa, 8);
    defer queue.deinit(test_gpa);
    try queue.push(test_gpa, .{ .idx = 2, .key_pressed = 107 }); // 1
    try queue.push(test_gpa, .{ .idx = 1, .key_pressed = 107 }); // 2
    try queue.push(test_gpa, .{ .idx = 4, .key_pressed = 108 }); // 3
    queue.drain();
    try t.expectEqual(0, queue.len());
}
