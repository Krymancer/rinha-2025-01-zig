const std = @import("std");

pub const Queue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    items: std.ArrayList([]const u8),
    max_size: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
        return Self{
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .items = std.ArrayList([]const u8).init(allocator),
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.items.items) |item| {
            self.allocator.free(item);
        }
        self.items.deinit();
    }

    pub fn enqueue(self: *Self, data: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len >= self.max_size) {
            std.log.warn("Queue is full ({any}/{any}). Rejecting payment: {s}", .{ self.items.items.len, self.max_size, data });
            return false;
        }

        const data_copy = try self.allocator.dupe(u8, data);
        try self.items.append(data_copy);
        std.log.info("Enqueued payment ({any}/{any}): {s}", .{ self.items.items.len, self.max_size, data });
        return true;
    }

    pub fn dequeue(self: *Self) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len == 0) {
            return null;
        }

        const result = self.items.pop();
        std.log.info("Dequeued payment ({d}/{d}): {any}", .{ self.items.items.len, self.max_size, result });
        return result;
    }

    pub fn size(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }

    pub fn isFull(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len >= self.max_size;
    }
};

var global_queue: ?Queue = null;
var queue_init_mutex: std.Thread.Mutex = std.Thread.Mutex{};

pub fn getGlobalQueue(allocator: std.mem.Allocator) *Queue {
    queue_init_mutex.lock();
    defer queue_init_mutex.unlock();

    if (global_queue == null) {
        const max_queue_size: usize = 1000;
        global_queue = Queue.init(allocator, max_queue_size);
        std.log.info("Initialized bounded LIFO queue with max size: {any}", .{max_queue_size});
    }

    return &global_queue.?;
}

pub fn enqueuePayment(allocator: std.mem.Allocator, correlation_id: []const u8) !bool {
    const queue = getGlobalQueue(allocator);
    return queue.enqueue(correlation_id);
}

pub fn dequeuePayment(allocator: std.mem.Allocator) ?[]const u8 {
    const queue = getGlobalQueue(allocator);
    return queue.dequeue();
}

pub fn isQueueFull(allocator: std.mem.Allocator) bool {
    const queue = getGlobalQueue(allocator);
    return queue.isFull();
}
