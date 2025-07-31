const std = @import("std");
const httpz = @import("httpz");
const PaymentClient = @import("payment_client.zig").PaymentClient;
const PaymentProcessorRequest = @import("payment_client.zig").PaymentProcessorRequest;

pub const PaymentRequest = struct {
    correlationId: []const u8,
    amount: f64,

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !PaymentRequest {
        var parsed = try std.json.parseFromSlice(PaymentRequest, allocator, json_str, .{});
        defer parsed.deinit();
        return parsed.value;
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

pub const PaymentService = struct {
    allocator: std.mem.Allocator,
    config: *const @import("config.zig").Config,
    default_stats: ProcessorSummary,
    fallback_stats: ProcessorSummary,
    last_health_check: i64,
    default_health: ProcessorHealth,
    fallback_health: ProcessorHealth,
    mutex: std.Thread.Mutex,

    const ProcessorHealth = struct {
        failing: bool,
        minResponseTime: u64,
        last_checked: i64,
    };

    pub fn init(allocator: std.mem.Allocator, config: *const @import("config.zig").Config) @This() {
        return .{
            .allocator = allocator,
            .config = config,
            .default_stats = ProcessorSummary{ .totalRequests = 0, .totalAmount = 0.0 },
            .fallback_stats = ProcessorSummary{ .totalRequests = 0, .totalAmount = 0.0 },
            .last_health_check = 0,
            .default_health = ProcessorHealth{ .failing = false, .minResponseTime = 100, .last_checked = 0 },
            .fallback_health = ProcessorHealth{ .failing = false, .minResponseTime = 200, .last_checked = 0 },
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    pub fn processPayment(self: *@This(), payment: PaymentRequest) !void {
        const processor = try self.chooseProcessor();

        const success = try self.sendPaymentToProcessor(processor, payment);

        if (success) {
            self.mutex.lock();
            defer self.mutex.unlock();

            switch (processor) {
                .default => {
                    self.default_stats.totalRequests += 1;
                    self.default_stats.totalAmount += payment.amount;
                },
                .fallback => {
                    self.fallback_stats.totalRequests += 1;
                    self.fallback_stats.totalAmount += payment.amount;
                },
            }
        } else {
            return error.PaymentProcessingFailed;
        }
    }

    const ProcessorType = enum {
        default,
        fallback,
    };

    fn chooseProcessor(self: *@This()) !ProcessorType {
        const now = std.time.timestamp();
        if (now - self.last_health_check > self.config.health_check_interval) {
            try self.updateHealthStatus();
            self.last_health_check = now;
        }
        if (!self.default_health.failing) {
            return .default;
        } else if (!self.fallback_health.failing) {
            return .fallback;
        } else {
            return .default;
        }
    }

    fn updateHealthStatus(self: *@This()) !void {
        var http_client = PaymentClient.init(self.allocator);
        defer http_client.deinit();

        const now = std.time.timestamp();

        if (http_client.getServiceHealth(self.config.payment_processor_default_url)) |health| {
            self.default_health.failing = health.failing;
            self.default_health.minResponseTime = health.minResponseTime;
            self.default_health.last_checked = now;
        } else |err| {
            std.log.err("Failed to check default processor health: {}", .{err});
            self.default_health.failing = true;
            self.default_health.last_checked = now;
        }

        if (http_client.getServiceHealth(self.config.payment_processor_fallback_url)) |health| {
            self.fallback_health.failing = health.failing;
            self.fallback_health.minResponseTime = health.minResponseTime;
            self.fallback_health.last_checked = now;
        } else |err| {
            std.log.err("Failed to check fallback processor health: {}", .{err});
            self.fallback_health.failing = true;
            self.fallback_health.last_checked = now;
        }
    }

    fn sendPaymentToProcessor(self: *@This(), processor: ProcessorType, payment: PaymentRequest) !bool {
        var payment_client = PaymentClient.init(self.allocator);
        defer payment_client.deinit();

        const url = switch (processor) {
            .default => self.config.payment_processor_default_url,
            .fallback => self.config.payment_processor_fallback_url,
        };

        const now = std.time.timestamp();
        var timestamp_buffer: [32]u8 = undefined;
        const timestamp_str = try std.fmt.bufPrint(&timestamp_buffer, "{}", .{now});

        const processor_request = PaymentProcessorRequest{
            .correlationId = payment.correlationId,
            .amount = payment.amount,
            .requestedAt = timestamp_str,
        };

        var attempts: u32 = 0;
        while (attempts < self.config.max_retries) {
            attempts += 1;

            if (payment_client.postPayment(url, processor_request)) |response| {
                self.allocator.free(response.message);
                return true;
            } else |err| {
                std.log.err("Payment attempt {} failed for processor {s}: {}", .{ attempts, @tagName(processor), err });

                if (attempts >= self.config.max_retries) {
                    return false;
                }

                std.time.sleep(std.time.ns_per_ms * 100 * attempts);
            }
        }

        return false;
    }

    pub fn getPaymentsSummary(self: *@This(), from: ?[]const u8, to: ?[]const u8) PaymentSummary {
        _ = from;
        _ = to;

        self.mutex.lock();
        defer self.mutex.unlock();

        return PaymentSummary{
            .default = self.default_stats,
            .fallback = self.fallback_stats,
        };
    }
};
