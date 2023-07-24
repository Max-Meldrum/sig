const std = @import("std");
const Atomic = std.atomic.Atomic;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;
const testing = std.testing;

/// A very basic mpmc channel implementation - TODO: replace with a legit channel impl
pub fn Channel(comptime T: type) type {
    return struct {
        buffer: std.ArrayList(T),
        lock: Mutex = .{},
        hasValue: Condition = .{},
        closed: Atomic(bool) = Atomic(bool).init(false),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, init_capacity: usize) Self {
            return .{
                .buffer = std.ArrayList(T).initCapacity(allocator, init_capacity) catch unreachable,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
        }

        pub fn send(self: *Self, value: T) void {
            self.lock.lock();
            defer self.lock.unlock();

            self.buffer.append(value) catch unreachable;
            self.hasValue.signal();
        }

        pub fn receive(self: *Self) ?T {
            self.lock.lock();
            defer self.lock.unlock();

            while (self.buffer.items.len == 0 and !self.closed.load(std.atomic.Ordering.SeqCst)) {
                self.hasValue.wait(&self.lock);
            }

            // channel closed so return null to signal no more items
            if (self.buffer.items.len == 0) {
                return null;
            }

            return self.buffer.pop();
        }

        pub fn close(self: *Self) void {
            self.closed.store(true, std.atomic.Ordering.SeqCst);
            self.hasValue.broadcast();
        }
    };
}

const Block = struct {
    num: u32 = 333,
    valid: bool = true,
};

const BlockChannel = Channel(Block);

const logger = std.log.scoped(.sync_channel_tests);

fn testReceiver(chan: *BlockChannel, recv_count: *usize) void {
    while (true) {
        _ = chan.receive() orelse break;
        recv_count.* += 1;
    }
}

fn testSender(chan: *BlockChannel, send_count: *usize) void {
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        std.time.sleep(std.time.ns_per_ms * 100);
        chan.send(Block{ .num = @intCast(i) });
        send_count.* += 1;
    }
    chan.close();
}

test "sync: channel works" {
    var ch = BlockChannel.init(testing.allocator, 100);
    defer ch.deinit();

    var recv_count: usize = 0;
    var send_count: usize = 0;
    var join1 = try std.Thread.spawn(.{}, testReceiver, .{ &ch, &recv_count });
    var join2 = try std.Thread.spawn(.{}, testSender, .{ &ch, &send_count });

    join1.join();
    join2.join();

    try testing.expect(recv_count == send_count);
}