const std = @import("std");
const httpz = @import("httpz");

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

const PaymentService = @This();

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

pub fn init(allocator: std.mem.Allocator, config: *const @import("config.zig").Config) PaymentService {
    return PaymentService{
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

pub fn deinit(self: *PaymentService) void {
    _ = self;
}

pub fn processPayment(self: *PaymentService, payment: PaymentRequest) !void {
    // Choose the best processor based on health and fees
    const processor = try self.chooseProcessor();

    // Attempt to process payment
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

fn chooseProcessor(self: *PaymentService) !ProcessorType {
    // Check if we need to update health status
    const now = std.time.timestamp();
    if (now - self.last_health_check > self.config.health_check_interval) {
        try self.updateHealthStatus();
        self.last_health_check = now;
    }

    // Choose processor based on health and response time
    // Default processor has lower fees, so prefer it when both are healthy
    if (!self.default_health.failing) {
        return .default;
    } else if (!self.fallback_health.failing) {
        return .fallback;
    } else {
        // Both failing, try default first (lower fees)
        return .default;
    }
}

fn updateHealthStatus(self: *PaymentService) !void {
    // This would make HTTP requests to health check endpoints
    // For now, we'll simulate health status
    // In a real implementation, you'd make requests to:
    // GET /payments/service-health on both processors

    // Placeholder implementation
    _ = self;
}

fn sendPaymentToProcessor(self: *PaymentService, processor: ProcessorType, payment: PaymentRequest) !bool {
    // This would make an HTTP POST request to the payment processor
    // For now, we'll simulate success

    _ = self;
    _ = processor;
    _ = payment;

    // In a real implementation, you'd:
    // 1. Create HTTP client
    // 2. Build JSON payload with correlationId, amount, and requestedAt
    // 3. POST to the appropriate processor URL
    // 4. Handle response and retries

    return true; // Simulated success
}

pub fn getPaymentsSummary(self: *PaymentService, from: ?[]const u8, to: ?[]const u8) PaymentSummary {
    _ = from;
    _ = to;

    self.mutex.lock();
    defer self.mutex.unlock();

    return PaymentSummary{
        .default = self.default_stats,
        .fallback = self.fallback_stats,
    };
}
