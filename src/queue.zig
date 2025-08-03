const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const State = @import("state.zig").State;
const PaymentProcessor = @import("payment_processor.zig").PaymentProcessor;
const PaymentData = @import("payment_processor.zig").PaymentData;
const PaymentResult = @import("payment_processor.zig").PaymentResult;
const config = @import("config.zig");
const money = @import("money.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub const QueueMessage = struct {
    amount: f64,
    correlation_id: []const u8,
};

pub const QueueOptions = struct {
    workers: u32 = 1,
    is_fire_mode: bool = false,
};

const WorkerData = struct {
    queue: *Queue,
    thread_id: u32,
    should_stop: *std.atomic.Value(bool),
    default_processor_url: []const u8,
    fallback_processor_url: []const u8,
};

pub const Queue = struct {
    const Self = @This();

    allocator: Allocator,
    state: *State,
    options: QueueOptions,

    // Queue implementation - use simple mutex-protected queue instead of lock-free
    messages: ArrayList(QueueMessage),

    // Worker management
    workers: ArrayList(Thread),
    worker_data: ArrayList(WorkerData),
    should_stop: std.atomic.Value(bool),

    // Synchronization
    mutex: Mutex,
    condition: Condition,

    // Request failure counter for fallback logic (incremented only on default processor failures)
    req_count: std.atomic.Value(u32),

    pub fn init(allocator: Allocator, state: *State, options: QueueOptions) !Self {
        var self = Self{
            .allocator = allocator,
            .state = state,
            .options = options,
            .messages = ArrayList(QueueMessage).init(allocator),
            .workers = ArrayList(Thread).init(allocator),
            .worker_data = ArrayList(WorkerData).init(allocator),
            .should_stop = std.atomic.Value(bool).init(false),
            .mutex = Mutex{},
            .condition = Condition{},
            .req_count = std.atomic.Value(u32).init(0),
        };

        // Start worker threads
        try self.startWorkers();

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Signal workers to stop
        self.should_stop.store(true, .release);

        // Wake up all workers
        self.condition.broadcast();

        // Wait for all workers to finish
        for (self.workers.items) |*worker| {
            worker.join();
        }

        self.workers.deinit();
        self.worker_data.deinit();
        self.messages.deinit();
    }

    fn startWorkers(self: *Self) !void {
        for (0..self.options.workers) |i| {
            const data = WorkerData{
                .queue = self,
                .thread_id = @intCast(i),
                .should_stop = &self.should_stop,
                .default_processor_url = config.payment_processor_urls.default,
                .fallback_processor_url = config.payment_processor_urls.fallback,
            };

            try self.worker_data.append(data);

            const thread = Thread.spawn(.{}, workerLoop, .{&self.worker_data.items[i]}) catch |err| {
                std.log.err("Failed to start worker thread {}: {}", .{ i, err });
                continue;
            };
            try self.workers.append(thread);
        }
    }

    pub fn enqueue(self: *Self, amount: f64, correlation_id: []const u8) !void {
        std.log.info("Enqueuing payment: amount={}, correlation_id={s}", .{ amount, correlation_id });
        const id_copy = try self.allocator.dupe(u8, correlation_id);

        const message = QueueMessage{
            .amount = amount,
            .correlation_id = id_copy,
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        // Add message to queue
        try self.messages.append(message);

        // Wake up a worker
        self.condition.signal();
    }

    fn workerLoop(data: *WorkerData) void {
        var processor = PaymentProcessor.init(data.queue.allocator, data.default_processor_url, data.fallback_processor_url) catch |err| {
            std.log.err("Failed to initialize payment processor: {}", .{err});
            return;
        };
        defer processor.deinit();

        while (!data.should_stop.load(.acquire)) {
            data.queue.mutex.lock();

            // Wait for work or stop signal
            while (data.queue.messages.items.len == 0 and !data.should_stop.load(.acquire)) {
                data.queue.condition.wait(&data.queue.mutex);
            }

            // Check again if we should stop after waking up
            if (data.should_stop.load(.acquire)) {
                data.queue.mutex.unlock();
                break;
            }

            // Dequeue message if available
            const maybe_message = if (data.queue.messages.items.len > 0) blk: {
                const message = data.queue.messages.orderedRemove(0);
                break :blk message;
            } else null;

            data.queue.mutex.unlock();

            if (maybe_message) |message| {
                processMessage(data.queue, &processor, message) catch |err| {
                    std.log.err("Failed to process message: {}", .{err});
                };

                // Free the copied correlation_id
                data.queue.allocator.free(message.correlation_id);
            }
        }
    }

    fn processMessage(self: *Self, processor: *PaymentProcessor, message: QueueMessage) !void {
        std.log.info("Processing payment: amount={d}, correlation_id={s}", .{ message.amount, message.correlation_id });

        // Create payment data
        var timestamp_buf: [32]u8 = undefined;
        const timestamp_str = try std.fmt.bufPrint(&timestamp_buf, "{}", .{std.time.milliTimestamp()});

        const payment_data = PaymentData{
            .requestedAt = timestamp_str,
            .amount = message.amount,
            .correlationId = message.correlation_id,
        };

        // ALWAYS try default processor first (matching Node.js logic)
        const result = processor.processWithDefault(payment_data) catch |err| blk: {
            std.log.warn("Default processor failed for payment {s}: {}", .{ message.correlation_id, err });

            // Increment request counter ONLY when default fails (like Node.js)
            const current_count = self.req_count.fetchAdd(1, .acq_rel);

            // Only try fallback if it's the 10th failure AND not in fire mode (exact Node.js logic)
            if (current_count % 10 == 0 and !self.options.is_fire_mode) {
                std.log.info("Trying fallback processor for payment {s} (failure_count={})", .{ message.correlation_id, current_count });

                const fallback_result = processor.processWithFallback(payment_data) catch |fallback_err| {
                    std.log.err("Both processors failed for payment {s}: default={}, fallback={}", .{ message.correlation_id, err, fallback_err });
                    return; // Payment failed completely
                };
                break :blk fallback_result;
            } else {
                std.log.err("Default processor failed and fallback not attempted for payment {s} (failure_count={}, fire_mode={})", .{ message.correlation_id, current_count, self.options.is_fire_mode });
                return; // Payment failed, no fallback attempted
            }
        };

        // Store successful result in state
        const amount_cents = money.floatToCents(message.amount);
        const timestamp_ms = std.time.milliTimestamp();

        switch (result.processor) {
            .default => {
                std.log.info("Successfully processed payment {s} with default processor", .{message.correlation_id});
                try self.state.default.push(amount_cents, timestamp_ms);
            },
            .fallback => {
                std.log.info("Successfully processed payment {s} with fallback processor", .{message.correlation_id});
                try self.state.fallback.push(amount_cents, timestamp_ms);
            },
        }
    }
};
