const std = @import("std");
const httpz = @import("httpz");
const PaymentClient = @import("payment_client.zig").PaymentClient;
const PaymentProcessorRequest = @import("payment_client.zig").PaymentProcessorRequest;
const PaymentQueue = @import("payment_queue.zig").PaymentQueue;

pub const PaymentRequest = struct {
    correlationId: []const u8,
    amount: f64,

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !PaymentRequest {
        var parsed = try std.json.parseFromSlice(PaymentRequest, allocator, json_str, .{});
        var result = parsed.value;
        // Duplicate strings to ensure they're owned by this request BEFORE deinitializing parsed
        result.correlationId = try allocator.dupe(u8, result.correlationId);
        parsed.deinit(); // Deinit after duplicating the string
        return result;
    }

    pub fn deinit(self: *PaymentRequest, allocator: std.mem.Allocator) void {
        // For now, skip memory cleanup to avoid double-free issues
        // In a production system, we'd need more careful memory management
        _ = self;
        _ = allocator;
    }
};

const PaymentSummary = struct {
    default: ProcessorSummary,
    fallback: ProcessorSummary,
};

const ProcessorSummary = struct {
    totalRequests: u64,
    totalAmount: f64,
};

const ProcessorType = enum {
    default,
    fallback,
};

const ProcessorHealth = struct {
    failing: std.atomic.Value(bool),
    minResponseTime: std.atomic.Value(u64),
    last_checked: std.atomic.Value(i64),

    pub fn init(failing: bool, min_response_time: u64) ProcessorHealth {
        return ProcessorHealth{
            .failing = std.atomic.Value(bool).init(failing),
            .minResponseTime = std.atomic.Value(u64).init(min_response_time),
            .last_checked = std.atomic.Value(i64).init(0),
        };
    }

    pub fn setFailing(self: *ProcessorHealth, failing: bool) void {
        self.failing.store(failing, .release);
    }

    pub fn isFailing(self: *ProcessorHealth) bool {
        return self.failing.load(.acquire);
    }

    pub fn setMinResponseTime(self: *ProcessorHealth, time: u64) void {
        self.minResponseTime.store(time, .release);
    }

    pub fn getMinResponseTime(self: *ProcessorHealth) u64 {
        return self.minResponseTime.load(.acquire);
    }

    pub fn updateLastChecked(self: *ProcessorHealth, timestamp: i64) void {
        self.last_checked.store(timestamp, .release);
    }

    pub fn getLastChecked(self: *ProcessorHealth) i64 {
        return self.last_checked.load(.acquire);
    }
};

pub const PaymentService = struct {
    allocator: std.mem.Allocator,
    config: *const @import("config.zig").Config,

    // Statistics
    default_stats: ProcessorSummary,
    fallback_stats: ProcessorSummary,
    stats_mutex: std.Thread.Mutex,

    // Health monitoring
    default_health: ProcessorHealth,
    fallback_health: ProcessorHealth,

    // Queue and workers
    payment_queue: PaymentQueue(PaymentRequest),
    failed_queue: PaymentQueue(PaymentRequest),
    worker_threads: []std.Thread,
    health_monitor_thread: ?std.Thread,

    // Control
    is_running: std.atomic.Value(bool),

    const WORKER_COUNT = 2;
    const HEALTH_CHECK_INTERVAL_MS = 1000; // 1 second
    const QUEUE_RETRY_INTERVAL_MS = 5000; // 5 seconds

    pub fn init(allocator: std.mem.Allocator, config: *const @import("config.zig").Config) !*PaymentService {
        const self = try allocator.create(PaymentService);

        self.* = PaymentService{
            .allocator = allocator,
            .config = config,
            .default_stats = ProcessorSummary{ .totalRequests = 0, .totalAmount = 0.0 },
            .fallback_stats = ProcessorSummary{ .totalRequests = 0, .totalAmount = 0.0 },
            .stats_mutex = std.Thread.Mutex{},
            .default_health = ProcessorHealth.init(false, 100), // Start assuming healthy
            .fallback_health = ProcessorHealth.init(false, 200),
            .payment_queue = PaymentQueue(PaymentRequest).init(allocator),
            .failed_queue = PaymentQueue(PaymentRequest).init(allocator),
            .worker_threads = try allocator.alloc(std.Thread, WORKER_COUNT),
            .health_monitor_thread = null,
            .is_running = std.atomic.Value(bool).init(false),
        };

        return self;
    }

    pub fn start(self: *PaymentService) !void {
        if (self.is_running.load(.acquire)) {
            return error.AlreadyRunning;
        }

        self.is_running.store(true, .release);

        // Start worker threads
        for (self.worker_threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, workerLoop, .{ self, i });
        }

        // Disable health monitor for now
        // self.health_monitor_thread = try std.Thread.spawn(.{}, healthMonitorLoop, .{self});

        // Disable failed queue retry for now
        // _ = try std.Thread.spawn(.{}, failedQueueRetryLoop, .{self});

        std.log.info("PaymentService started with {} workers", .{WORKER_COUNT});
    }

    pub fn stop(self: *PaymentService) void {
        if (!self.is_running.load(.acquire)) {
            return;
        }

        std.log.info("Stopping PaymentService...", .{});
        self.is_running.store(false, .release);

        // Close queues to wake up waiting threads
        self.payment_queue.close();
        self.failed_queue.close();

        // Wait for worker threads
        for (self.worker_threads) |thread| {
            thread.join();
        }

        // Wait for health monitor
        if (self.health_monitor_thread) |thread| {
            thread.join();
        }

        std.log.info("PaymentService stopped", .{});
    }

    pub fn deinit(self: *PaymentService) void {
        self.stop();
        self.payment_queue.deinit();
        self.failed_queue.deinit();
        self.allocator.free(self.worker_threads);
        self.allocator.destroy(self);
    }

    pub fn submitPayment(self: *PaymentService, payment: PaymentRequest) !void {
        try self.payment_queue.push(payment);
        std.log.debug("Payment queued: {s} (queue size: {})", .{ payment.correlationId, self.payment_queue.getSize() });
    }

    fn workerLoop(self: *PaymentService, worker_id: usize) void {
        std.log.info("Worker {} started", .{worker_id});

        var payment_client = PaymentClient.init(self.allocator);
        defer payment_client.deinit();

        while (self.is_running.load(.acquire)) {
            if (self.payment_queue.waitAndPop()) |payment| {
                std.log.debug("Worker {}: Processing payment {s}", .{ worker_id, payment.correlationId });

                self.processPaymentInternal(&payment_client, payment) catch |err| {
                    std.log.err("Worker {}: Failed to process payment {s}: {}", .{ worker_id, payment.correlationId, err });

                    // Add to failed queue for retry
                    const failed_payment = PaymentRequest{
                        .correlationId = self.allocator.dupe(u8, payment.correlationId) catch continue,
                        .amount = payment.amount,
                    };
                    self.failed_queue.push(failed_payment) catch {
                        std.log.err("Failed to queue payment for retry: {s}", .{payment.correlationId});
                    };
                };

                // Clean up the processed payment
                var mut_payment = payment;
                mut_payment.deinit(self.allocator);
            }
        }

        std.log.info("Worker {} stopped", .{worker_id});
    }

    fn healthMonitorLoop(self: *PaymentService) void {
        std.log.info("Health monitor started", .{});

        var payment_client = PaymentClient.init(self.allocator);
        defer payment_client.deinit();

        while (self.is_running.load(.acquire)) {
            self.updateHealthStatus(&payment_client);
            std.time.sleep(HEALTH_CHECK_INTERVAL_MS * std.time.ns_per_ms);
        }

        std.log.info("Health monitor stopped", .{});
    }

    fn failedQueueRetryLoop(self: *PaymentService) void {
        std.log.info("Failed queue retry loop started", .{});

        while (self.is_running.load(.acquire)) {
            // Try to requeue failed payments when processors are healthy
            if (!self.default_health.isFailing() or !self.fallback_health.isFailing()) {
                var retry_count: u32 = 0;
                const max_retries = 10; // Limit retries per cycle

                while (retry_count < max_retries) {
                    if (self.failed_queue.pop()) |failed_payment| {
                        self.payment_queue.push(failed_payment) catch {
                            // If main queue is full, put it back in failed queue
                            self.failed_queue.push(failed_payment) catch {};
                            break;
                        };
                        retry_count += 1;
                    } else {
                        break;
                    }
                }

                if (retry_count > 0) {
                    std.log.info("Requeued {} failed payments", .{retry_count});
                }
            }

            std.time.sleep(QUEUE_RETRY_INTERVAL_MS * std.time.ns_per_ms);
        }

        std.log.info("Failed queue retry loop stopped", .{});
    }

    fn processPaymentInternal(self: *PaymentService, payment_client: *PaymentClient, payment: PaymentRequest) !void {
        const processor = self.chooseProcessor();
        std.log.debug("Chose processor: {s} for payment {s}", .{ @tagName(processor), payment.correlationId });

        const start_time = std.time.milliTimestamp();
        const success = self.sendPaymentToProcessor(payment_client, processor, payment) catch |err| {
            std.log.err("sendPaymentToProcessor failed: {}", .{err});
            return err;
        };
        const response_time = std.time.milliTimestamp() - start_time;

        if (success) {
            self.updateStats(processor, payment.amount);
            std.log.debug("Payment processed successfully: {s} via {s} in {}ms", .{ payment.correlationId, @tagName(processor), response_time });
        } else {
            std.log.err("Payment processing failed for {s} via {s}", .{ payment.correlationId, @tagName(processor) });
            return error.PaymentProcessingFailed;
        }
    }
    fn chooseProcessor(self: *PaymentService) ProcessorType {
        // For now, just alternate between processors to test both
        // Disable complex health checking until we get basic functionality working
        const request_count = self.default_stats.totalRequests + self.fallback_stats.totalRequests;
        if (request_count % 2 == 0) {
            return .default;
        } else {
            return .fallback;
        }
    }

    fn sendPaymentToProcessor(self: *PaymentService, payment_client: *PaymentClient, processor: ProcessorType, payment: PaymentRequest) !bool {
        const base_url = switch (processor) {
            .default => self.config.payment_processor_default_url,
            .fallback => self.config.payment_processor_fallback_url,
        };

        // Construct full payment URL
        const url = try std.fmt.allocPrint(self.allocator, "{s}/payments", .{base_url});
        defer self.allocator.free(url);

        // Use simple hardcoded timestamp for now
        const timestamp_str = "2025-01-31T12:00:00.000Z";

        const processor_request = PaymentProcessorRequest{
            .correlationId = payment.correlationId,
            .amount = payment.amount,
            .requestedAt = timestamp_str,
        };

        if (payment_client.postPayment(url, processor_request)) |response| {
            self.allocator.free(response.message);
            return true;
        } else |err| {
            std.log.err("Payment failed for processor {s}: {}", .{ @tagName(processor), err });
            return false;
        }
    }

    fn updateHealthStatus(self: *PaymentService, payment_client: *PaymentClient) void {
        const now = std.time.timestamp();

        // Check default processor
        if (payment_client.getServiceHealth(self.config.payment_processor_default_url)) |health| {
            self.default_health.setFailing(health.failing);
            self.default_health.setMinResponseTime(health.minResponseTime);
            self.default_health.updateLastChecked(now);
        } else |err| {
            std.log.err("Failed to check default processor health: {}", .{err});
            self.default_health.setFailing(true);
            self.default_health.updateLastChecked(now);
        }

        // Check fallback processor
        if (payment_client.getServiceHealth(self.config.payment_processor_fallback_url)) |health| {
            self.fallback_health.setFailing(health.failing);
            self.fallback_health.setMinResponseTime(health.minResponseTime);
            self.fallback_health.updateLastChecked(now);
        } else |err| {
            std.log.err("Failed to check fallback processor health: {}", .{err});
            self.fallback_health.setFailing(true);
            self.fallback_health.updateLastChecked(now);
        }
    }

    fn updateStats(self: *PaymentService, processor: ProcessorType, amount: f64) void {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();

        switch (processor) {
            .default => {
                self.default_stats.totalRequests += 1;
                self.default_stats.totalAmount += amount;
            },
            .fallback => {
                self.fallback_stats.totalRequests += 1;
                self.fallback_stats.totalAmount += amount;
            },
        }
    }

    pub fn getPaymentsSummary(self: *PaymentService, from: ?[]const u8, to: ?[]const u8) PaymentSummary {
        _ = from;
        _ = to;

        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();

        return PaymentSummary{
            .default = self.default_stats,
            .fallback = self.fallback_stats,
        };
    }

    pub fn getHealthStatus(self: *PaymentService) struct { default_failing: bool, fallback_failing: bool, queue_size: u32, failed_queue_size: u32 } {
        return .{
            .default_failing = self.default_health.isFailing(),
            .fallback_failing = self.fallback_health.isFailing(),
            .queue_size = self.payment_queue.getSize(),
            .failed_queue_size = self.failed_queue.getSize(),
        };
    }
};
