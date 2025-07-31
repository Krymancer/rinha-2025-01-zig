const std = @import("std");

allocator: std.mem.Allocator,
client: std.http.Client,

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

const HttpClient = struct {
    pub fn init(allocator: std.mem.Allocator) @This() {
        return @This(){
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *@This()) void {
        self.client.deinit();
    }

    pub fn postPayment(self: *@This(), url: []const u8, payment: PaymentProcessorRequest) !PaymentProcessorResponse {
        // Create JSON payload
        var json_buffer = std.ArrayList(u8).init(self.allocator);
        defer json_buffer.deinit();

        try std.json.stringify(payment, .{}, json_buffer.writer());

        // Make HTTP request
        var req = try self.client.open(.POST, try std.Uri.parse(url), .{
            .server_header_buffer = try self.allocator.alloc(u8, 4096),
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = json_buffer.items.len };
        try req.send();
        try req.writeAll(json_buffer.items);
        try req.finish();
        try req.wait();

        // Read response
        const response_body = try req.readAll(self.allocator, 8192);
        defer self.allocator.free(response_body);

        if (req.response.status != .ok) {
            return error.PaymentProcessorError;
        }

        // Parse response
        var parser = std.json.Parser.init(self.allocator, false);
        defer parser.deinit();

        var tree = try parser.parse(response_body);
        defer tree.deinit();

        const root = tree.root.Object;
        const message = root.get("message") orelse return error.InvalidResponse;

        return PaymentProcessorResponse{
            .message = try self.allocator.dupe(u8, message.String),
        };
    }

    pub fn getServiceHealth(self: *@This(), url: []const u8) !HealthCheckResponse {
        const health_url = try std.fmt.allocPrint(self.allocator, "{s}/payments/service-health", .{url});
        defer self.allocator.free(health_url);

        var req = try self.client.open(.GET, try std.Uri.parse(health_url), .{
            .server_header_buffer = try self.allocator.alloc(u8, 4096),
        });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        // Read response
        const response_body = try req.readAll(self.allocator, 8192);
        defer self.allocator.free(response_body);

        if (req.response.status == .too_many_requests) {
            return error.TooManyRequests;
        }

        if (req.response.status != .ok) {
            return error.HealthCheckFailed;
        }

        // Parse response
        var parser = std.json.Parser.init(self.allocator, false);
        defer parser.deinit();

        var tree = try parser.parse(response_body);
        defer tree.deinit();

        const root = tree.root.Object;
        const failing = root.get("failing") orelse return error.InvalidResponse;
        const min_response_time = root.get("minResponseTime") orelse return error.InvalidResponse;

        return HealthCheckResponse{
            .failing = failing.Bool,
            .minResponseTime = @intCast(min_response_time.Integer),
        };
    }
};
