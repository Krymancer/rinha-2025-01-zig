const std = @import("std");
const http = std.http;
const print = std.debug.print;
const models = @import("../models/payment.zig");

pub const ProcessorError = error{
    HttpRequestFailed,
    InvalidResponse,
    ProcessorUnavailable,
    NetworkError,
    OutOfMemory,
    JsonParseError,
};

pub const HealthStatus = struct {
    failing: bool,
    minResponseTime: u32,
};

pub const ProcessorResponse = struct {
    message: []const u8,
};

pub const ProcessorClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    default_url: []const u8,
    fallback_url: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: struct {}) Self {
        _ = config;

        return Self{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator },
            .default_url = "http://payment-processor-default:8080",
            .fallback_url = "http://payment-processor-fallback:8080",
        };
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }

    fn getProcessorUrl(self: *Self, processor: models.PaymentProcessor) []const u8 {
        return switch (processor) {
            .default => self.default_url,
            .fallback => self.fallback_url,
        };
    }

    pub fn checkHealth(self: *Self, processor: models.PaymentProcessor) !HealthStatus {
        const url = self.getProcessorUrl(processor);
        const health_endpoint = try std.fmt.allocPrint(self.allocator, "{s}/payments/service-health", .{url});
        defer self.allocator.free(health_endpoint);

        const uri = std.Uri.parse(health_endpoint) catch return ProcessorError.InvalidResponse;

        var request = self.client.open(.GET, uri, .{
            .server_header_buffer = try self.allocator.alloc(u8, 1024),
        }) catch |err| {
            print("Health check failed for {s}: {}\n", .{ processor.toString(), err });
            return HealthStatus{ .failing = true, .minResponseTime = 9999 };
        };
        defer request.deinit();

        request.send() catch |err| {
            print("Health check send failed for {s}: {}\n", .{ processor.toString(), err });
            return HealthStatus{ .failing = true, .minResponseTime = 9999 };
        };

        request.finish() catch |err| {
            print("Health check finish failed for {s}: {}\n", .{ processor.toString(), err });
            return HealthStatus{ .failing = true, .minResponseTime = 9999 };
        };

        request.wait() catch |err| {
            print("Health check wait failed for {s}: {}\n", .{ processor.toString(), err });
            return HealthStatus{ .failing = true, .minResponseTime = 9999 };
        };

        if (request.response.status != .ok) {
            print("Health check returned status {} for {s}\n", .{ request.response.status, processor.toString() });
            return HealthStatus{ .failing = true, .minResponseTime = 9999 };
        }

        // Read response body
        const body = request.reader().readAllAlloc(self.allocator, 1024) catch |err| {
            print("Failed to read health response for {s}: {}\n", .{ processor.toString(), err });
            return HealthStatus{ .failing = true, .minResponseTime = 9999 };
        };
        defer self.allocator.free(body);

        // Parse JSON response
        var parsed = std.json.parseFromSlice(struct {
            failing: bool,
            minResponseTime: u32,
        }, self.allocator, body, .{}) catch |err| {
            print("Failed to parse health response for {s}: {}\n", .{ processor.toString(), err });
            return HealthStatus{ .failing = true, .minResponseTime = 9999 };
        };
        defer parsed.deinit();

        print("Health check for {s}: failing={}, minResponseTime={}\n", .{ processor.toString(), parsed.value.failing, parsed.value.minResponseTime });

        return HealthStatus{
            .failing = parsed.value.failing,
            .minResponseTime = parsed.value.minResponseTime,
        };
    }

    pub fn processPayment(self: *Self, request: models.PaymentProcessorRequest, processor: models.PaymentProcessor) !ProcessorResponse {
        const url = self.getProcessorUrl(processor);
        const payment_endpoint = try std.fmt.allocPrint(self.allocator, "{s}/payments", .{url});
        defer self.allocator.free(payment_endpoint);

        // Create JSON payload
        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"correlationId":"{s}","amount":{d},"requestedAt":"{s}"}}
        , .{ request.correlationId, request.amount, request.requestedAt });
        defer self.allocator.free(payload);

        const uri = std.Uri.parse(payment_endpoint) catch return ProcessorError.InvalidResponse;

        var req = self.client.open(.POST, uri, .{
            .server_header_buffer = try self.allocator.alloc(u8, 1024),
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        }) catch |err| {
            print("Failed to create payment request for {s}: {}\n", .{ processor.toString(), err });
            return ProcessorError.HttpRequestFailed;
        };
        defer req.deinit();

        req.send() catch |err| {
            print("Failed to send payment request for {s}: {}\n", .{ processor.toString(), err });
            return ProcessorError.HttpRequestFailed;
        };

        // Write request body
        req.writeAll(payload) catch |err| {
            print("Failed to write payment request body for {s}: {}\n", .{ processor.toString(), err });
            return ProcessorError.HttpRequestFailed;
        };

        req.finish() catch |err| {
            print("Failed to finish payment request for {s}: {}\n", .{ processor.toString(), err });
            return ProcessorError.HttpRequestFailed;
        };

        req.wait() catch |err| {
            print("Failed to wait for payment response from {s}: {}\n", .{ processor.toString(), err });
            return ProcessorError.HttpRequestFailed;
        };

        if (req.response.status != .ok) {
            print("Payment request returned status {} for {s}\n", .{ req.response.status, processor.toString() });
            return ProcessorError.ProcessorUnavailable;
        }

        // Read response body
        const body = req.reader().readAllAlloc(self.allocator, 1024) catch |err| {
            print("Failed to read payment response from {s}: {}\n", .{ processor.toString(), err });
            return ProcessorError.HttpRequestFailed;
        };
        defer self.allocator.free(body);

        // Parse JSON response
        var parsed = std.json.parseFromSlice(struct {
            message: []const u8,
        }, self.allocator, body, .{}) catch |err| {
            print("Failed to parse payment response from {s}: {}\n", .{ processor.toString(), err });
            return ProcessorError.JsonParseError;
        };
        defer parsed.deinit();

        print("Payment processed successfully by {s}: {s}\n", .{ processor.toString(), parsed.value.message });

        const message_copy = try self.allocator.dupe(u8, parsed.value.message);
        return ProcessorResponse{
            .message = message_copy,
        };
    }
};

pub fn formatTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();
    const dt = std.time.DateTime.fromTimestamp(timestamp);

    return std.fmt.allocPrint(allocator, "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.000Z", .{
        dt.year, dt.month,  dt.day,
        dt.hour, dt.minute, dt.second,
    });
}
