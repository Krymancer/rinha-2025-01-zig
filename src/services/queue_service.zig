const std = @import("std");

// Redis-like queue implementation using TCP connection to Redis
pub const Queue = struct {
    stream: ?std.net.Stream,
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) Queue {
        return Queue{
            .stream = null,
            .allocator = allocator,
            .host = host,
            .port = port,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.stream) |stream| {
            stream.close();
        }
    }

    fn connect(self: *Queue) !void {
        if (self.stream != null) return; // Already connected

        // Use tcpConnectToHost for hostname resolution
        self.stream = try std.net.tcpConnectToHost(self.allocator, self.host, self.port);
        std.log.info("Connected to Redis at {s}:{}", .{ self.host, self.port });
    }

    fn sendCommand(self: *Queue, command: []const u8) !void {
        try self.connect();
        if (self.stream) |stream| {
            _ = try stream.writeAll(command);

            // Read response (simplified - in real implementation would parse RESP protocol)
            var buffer: [1024]u8 = undefined;
            _ = try stream.read(&buffer);
        }
    }

    pub fn enqueue(self: *Queue, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Use Redis LPUSH command to add to queue
        const command = try std.fmt.allocPrint(self.allocator, "*3\r\n$5\r\nLPUSH\r\n$13\r\npayment_queue\r\n${}\r\n{s}\r\n", .{ data.len, data });
        defer self.allocator.free(command);

        try self.sendCommand(command);
        std.log.info("Enqueued payment: {s}", .{data});
    }

    pub fn dequeue(self: *Queue) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Use Redis BRPOP command to get from queue
        const command = "*3\r\n$5\r\nBRPOP\r\n$13\r\npayment_queue\r\n$1\r\n1\r\n";

        self.sendCommand(command) catch |err| {
            std.log.err("Failed to dequeue: {}", .{err});
            return null;
        };

        // In a real implementation, would parse Redis response
        // For now, return null if no items
        return null;
    }

    pub fn size(self: *Queue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Use Redis LLEN command to get queue size
        const command = "*2\r\n$4\r\nLLEN\r\n$13\r\npayment_queue\r\n";

        self.sendCommand(command) catch |err| {
            std.log.err("Failed to get queue size: {}", .{err});
            return 0;
        };

        // In a real implementation, would parse Redis response
        // For now, return 0
        return 0;
    }
};

var global_queue: ?Queue = null;
var queue_init_mutex: std.Thread.Mutex = std.Thread.Mutex{};

pub fn getGlobalQueue(allocator: std.mem.Allocator) *Queue {
    queue_init_mutex.lock();
    defer queue_init_mutex.unlock();

    if (global_queue == null) {
        const redis_host = std.process.getEnvVarOwned(allocator, "REDIS_HOST") catch allocator.dupe(u8, "localhost") catch "localhost";
        const redis_port: u16 = 6379;

        global_queue = Queue.init(allocator, redis_host, redis_port);
        std.log.info("Initialized Redis queue at {s}:{}", .{ redis_host, redis_port });
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
