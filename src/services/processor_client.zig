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

        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        try headers.append("content-type", "application/json");

        const uri = try std.Uri.parse(full_url);
        var request = try self.http_client.open(.POST, uri, headers, .{});
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = payload.len };
        try request.send(.{});
        try request.writeAll(payload);
        try request.finish();
        try request.wait();

        if (request.response.status != .ok) {
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
        var request = try self.http_client.open(.GET, uri, .{}, .{});
        defer request.deinit();

        try request.send(.{});
        try request.finish();
        try request.wait();

        if (request.response.status != .ok) {
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
    const timestamp = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(timestamp);
    const datetime = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const year_day = datetime.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        0, // hours
        0, // minutes
        0, // seconds
    });
}
