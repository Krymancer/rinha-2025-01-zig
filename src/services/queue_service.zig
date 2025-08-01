const std = @import("std");

// Simple Redis-like queue implementation using in-memory queue for now
// In production, you'd use actual Redis client
pub const Queue = struct {
    mutex: std.Thread.Mutex,
    items: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Queue {
        return Queue{
            .mutex = std.Thread.Mutex{},
            .items = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.items.items) |item| {
            self.allocator.free(item);
        }
        self.items.deinit();
    }

    pub fn enqueue(self: *Queue, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_data = try self.allocator.dupe(u8, data);
        try self.items.append(owned_data);
    }

    pub fn dequeue(self: *Queue) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    pub fn size(self: *Queue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }
};

var global_queue: ?Queue = null;
var queue_init_mutex: std.Thread.Mutex = std.Thread.Mutex{};

pub fn getGlobalQueue(allocator: std.mem.Allocator) *Queue {
    queue_init_mutex.lock();
    defer queue_init_mutex.unlock();

    if (global_queue == null) {
        global_queue = Queue.init(allocator);
    }

    return &global_queue.?;
}

pub fn enqueuePayment(allocator: std.mem.Allocator, correlation_id: []const u8) !void {
    const queue = getGlobalQueue(allocator);
    try queue.enqueue(correlation_id);
}

pub fn dequeuePayment(allocator: std.mem.Allocator) ?[]const u8 {
    const queue = getGlobalQueue(allocator);
    return queue.dequeue();
}
