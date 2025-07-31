const std = @import("std");
const curl = @import("curl");

pub const PaymentProcessorRequest = struct {
    correlationId: []const u8,
    amount: f64,
    requestedAt: []const u8,
};

pub const PaymentProcessorResponse = struct {
    message: []const u8,
};

pub const HealthCheckResponse = struct {
    failing: bool,
    minResponseTime: u64,
};

pub const PaymentClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *@This()) void {
        self.client.deinit();
    }

    pub fn postPayment(self: *@This(), url: []const u8, payment: PaymentProcessorRequest) !PaymentProcessorResponse {
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();
        try std.json.stringify(payment, .{}, payload.writer());

        std.log.debug("Sending payment to {s}: {s}", .{ url, payload.items });

        // Use curl subprocess for proper headers
        var child = std.process.Child.init(&[_][]const u8{
            "curl",        "-s",                             "-X", "POST",               url,
            "-H",          "Content-Type: application/json", "-H", "X-Rinha-Token: 123", "-d",
            payload.items,
        }, self.allocator);

        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const result = try child.wait();

        if (result != .Exited or result.Exited != 0) {
            std.log.debug("curl failed with exit code: {}", .{result});
            return error.PaymentProcessorError;
        }

        std.log.debug("Payment sent successfully via curl", .{});

        return PaymentProcessorResponse{
            .message = try self.allocator.dupe(u8, "Payment processed via curl"),
        };
    }

    pub fn getServiceHealth(self: *@This(), url: []const u8) !HealthCheckResponse {
        const health_url = try std.fmt.allocPrint(self.allocator, "{s}/service-health", .{url});
        defer self.allocator.free(health_url);

        var buf: [4096]u8 = undefined;
        var req = try self.client.open(.GET, try std.Uri.parse(health_url), .{
            .server_header_buffer = &buf,
        });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        // Return failure if health check endpoint is not available or returns error
        if (req.response.status == .too_many_requests) {
            return error.TooManyRequests;
        }

        if (req.response.status != .ok) {
            return error.HealthCheckFailed;
        }

        var response_buffer: [8192]u8 = undefined;
        const bytes_read = try req.readAll(&response_buffer);
        const response_body = try self.allocator.dupe(u8, response_buffer[0..bytes_read]);
        defer self.allocator.free(response_body);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const failing = root.get("failing") orelse return error.InvalidResponse;
        const min_response_time = root.get("minResponseTime") orelse return error.InvalidResponse;

        return HealthCheckResponse{
            .failing = failing.bool,
            .minResponseTime = @intCast(min_response_time.integer),
        };
    }
};
