const std = @import("std");
const models = @import("../models/payment.zig");

pub const ProcessorConfig = struct {
    default_url: []const u8 = "http://payment-processor-default:8080",
    fallback_url: []const u8 = "http://payment-processor-fallback:8080",
};

pub const HealthStatus = struct {
    failing: bool,
    minResponseTime: i64,
};

pub const ProcessorClient = struct {
    allocator: std.mem.Allocator,
    config: ProcessorConfig,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, config: ProcessorConfig) ProcessorClient {
        return ProcessorClient{
            .allocator = allocator,
            .config = config,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *ProcessorClient) void {
        self.http_client.deinit();
    }

    pub fn processPayment(
        self: *ProcessorClient,
        payment: models.PaymentProcessorRequest,
        processor: models.PaymentProcessor,
    ) !models.PaymentResponse {
        const url = switch (processor) {
            .default => self.config.default_url,
            .fallback => self.config.fallback_url,
        };

        const full_url = try std.fmt.allocPrint(self.allocator, "{s}/payments", .{url});
        defer self.allocator.free(full_url);

        const payload = try std.json.stringifyAlloc(self.allocator, payment, .{});
        defer self.allocator.free(payload);

        const uri = try std.Uri.parse(full_url);
        var server_header_buffer: [8192]u8 = undefined;
        var request = try self.http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = payload.len };
        try request.send();
        try request.writeAll(payload);
        try request.finish();
        try request.wait();

        std.log.info("Payment request to {s}: status={s}", .{ url, @tagName(request.response.status) });

        if (request.response.status != .ok) {
            std.log.err("Payment processor {s} returned status: {s}", .{ url, @tagName(request.response.status) });
            return error.ProcessorError;
        }

        const response_body = try request.reader().readAllAlloc(self.allocator, 1024);
        defer self.allocator.free(response_body);

        const parsed = try std.json.parseFromSlice(models.PaymentResponse, self.allocator, response_body, .{});
        defer parsed.deinit();

        return models.PaymentResponse{
            .message = try self.allocator.dupe(u8, parsed.value.message),
        };
    }

    pub fn checkHealth(
        self: *ProcessorClient,
        processor: models.PaymentProcessor,
    ) !HealthStatus {
        const url = switch (processor) {
            .default => self.config.default_url,
            .fallback => self.config.fallback_url,
        };

        const full_url = try std.fmt.allocPrint(self.allocator, "{s}/payments/service-health", .{url});
        defer self.allocator.free(full_url);

        const uri = try std.Uri.parse(full_url);
        var server_header_buffer: [8192]u8 = undefined;
        var request = try self.http_client.open(.GET, uri, .{
            .server_header_buffer = &server_header_buffer,
        });
        defer request.deinit();

        try request.send();
        try request.finish();
        try request.wait();

        std.log.info("Health check for {s}: status={s}", .{ url, @tagName(request.response.status) });

        if (request.response.status != .ok) {
            std.log.err("Health check failed for {s}: status={s}", .{ url, @tagName(request.response.status) });
            return error.HealthCheckFailed;
        }

        const response_body = try request.reader().readAllAlloc(self.allocator, 1024);
        defer self.allocator.free(response_body);

        const parsed = try std.json.parseFromSlice(HealthStatus, self.allocator, response_body, .{});
        defer parsed.deinit();

        return parsed.value;
    }
};

pub fn formatTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "2024-01-01T00:00:00.000Z", .{});
}
