const std = @import("std");
const net = std.net;
const json = std.json;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");

pub const PaymentData = struct {
    requestedAt: []const u8,
    amount: f64,
    correlationId: []const u8,
};

pub const PaymentResult = struct {
    processor: config.ProcessorType,
    data: PaymentData,
};

pub const CheckHealthResponse = struct {
    failing: bool,
    minResponseTime: f64,
};

pub const HttpResponse = struct {
    status_code: u16,
    body: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *HttpResponse) void {
        self.allocator.free(self.body);
    }
};

pub const HttpPool = struct {
    const Self = @This();

    allocator: Allocator,
    base_url: []const u8,
    connections: std.ArrayList(*HttpConnection),
    mutex: Thread.Mutex,

    const HttpConnection = struct {
        stream: ?net.Stream,
        in_use: bool,

        pub fn init() HttpConnection {
            return HttpConnection{
                .stream = null,
                .in_use = false,
            };
        }

        pub fn deinit(self: *HttpConnection) void {
            if (self.stream) |stream| {
                stream.close();
            }
        }
    };

    pub fn init(allocator: Allocator, base_url: []const u8) !Self {
        std.log.info("Initializing HttpPool with URL: {s}", .{base_url});

        // Validate base_url
        if (base_url.len == 0) {
            return error.InvalidURL;
        }

        const pool = Self{
            .allocator = allocator,
            .base_url = base_url, // Don't duplicate for now, use the original string literal
            .connections = std.ArrayList(*HttpConnection).init(allocator),
            .mutex = Thread.Mutex{},
        };

        // Don't pre-create connection pool to avoid allocator issues in worker threads
        // Connections will be created on-demand

        return pool;
    }

    pub fn deinit(self: *Self) void {
        for (self.connections.items) |connection| {
            connection.deinit();
            self.allocator.destroy(connection);
        }
        self.connections.deinit();
        // Don't free base_url since we're not duplicating it anymore
    }

    pub fn request(self: *Self, method: []const u8, path: []const u8, body: ?[]const u8) !HttpResponse {
        // Parse URL to get host and port
        const url_without_protocol = if (std.mem.startsWith(u8, self.base_url, "http://"))
            self.base_url[7..]
        else
            self.base_url;

        var parts = std.mem.splitScalar(u8, url_without_protocol, ':');
        const host = parts.next() orelse return error.InvalidURL;
        const port_str = parts.next() orelse "80";
        const port = try std.fmt.parseInt(u16, port_str, 10);

        // Create connection - use localhost for testing
        const address = if (std.mem.eql(u8, host, "payment-processor-default") or std.mem.eql(u8, host, "payment-processor-fallback"))
            try net.Address.parseIp("127.0.0.1", port)
        else
            try net.Address.parseIp(host, port);
        const stream = try net.tcpConnectToAddress(address);
        defer stream.close();

        // Build HTTP request
        var request_buf = std.ArrayList(u8).init(self.allocator);
        defer request_buf.deinit();

        try request_buf.writer().print("{s} {s} HTTP/1.1\r\n", .{ method, path });
        try request_buf.writer().print("Host: {s}:{d}\r\n", .{ host, port });
        try request_buf.writer().print("Content-Type: application/json\r\n", .{});
        try request_buf.writer().print("Connection: close\r\n", .{});

        if (body) |b| {
            try request_buf.writer().print("Content-Length: {d}\r\n", .{b.len});
            try request_buf.writer().print("\r\n{s}", .{b});
        } else {
            try request_buf.writer().print("Content-Length: 0\r\n\r\n", .{});
        }

        // Send request
        _ = try stream.writeAll(request_buf.items);

        // Read response
        var response_buf = std.ArrayList(u8).init(self.allocator);
        defer response_buf.deinit();

        var buffer: [1024]u8 = undefined;
        while (true) {
            const bytes_read = stream.read(&buffer) catch break;
            if (bytes_read == 0) break;
            try response_buf.appendSlice(buffer[0..bytes_read]);
        }

        // Parse HTTP response
        const response_data = response_buf.items;
        const header_end = std.mem.indexOf(u8, response_data, "\r\n\r\n") orelse return error.InvalidResponse;
        const headers = response_data[0..header_end];
        const body_start = header_end + 4;

        // Extract status code
        const first_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return error.InvalidResponse;
        const first_line = headers[0..first_line_end];
        var status_parts = std.mem.splitScalar(u8, first_line, ' ');
        _ = status_parts.next(); // Skip HTTP version
        const status_str = status_parts.next() orelse return error.InvalidResponse;
        const status_code = try std.fmt.parseInt(u16, status_str, 10);

        // Copy response body
        const response_body = try self.allocator.dupe(u8, response_data[body_start..]);

        return HttpResponse{
            .status_code = status_code,
            .body = response_body,
            .allocator = self.allocator,
        };
    }

    pub fn prewarmConnections(self: *Self) !void {
        // Prewarm pool by making health check requests
        for (0..10) |_| {
            var response = self.request("GET", "/payments/service-health", null) catch continue;
            response.deinit();
            // Small delay between requests
            std.time.sleep(10_000_000); // 10ms
        }
    }
};

pub const PaymentProcessor = struct {
    const Self = @This();

    allocator: Allocator,
    default_pool: HttpPool,
    fallback_pool: HttpPool,

    pub fn init(allocator: Allocator, default_url: []const u8, fallback_url: []const u8) !Self {
        const processor = Self{
            .allocator = allocator,
            .default_pool = try HttpPool.init(allocator, default_url),
            .fallback_pool = try HttpPool.init(allocator, fallback_url),
        };

        // Don't prewarm pools to avoid allocator issues in worker threads
        // processor.prewarmPools() catch |err| {
        //     std.log.warn("Failed to prewarm connection pools: {}", .{err});
        // };

        return processor;
    }

    pub fn deinit(self: *Self) void {
        self.default_pool.deinit();
        self.fallback_pool.deinit();
    }

    fn prewarmPools(self: *Self) !void {
        // Prewarm both pools in parallel
        const default_thread = try Thread.spawn(.{}, struct {
            fn run(pool: *HttpPool) void {
                pool.prewarmConnections() catch {};
            }
        }.run, .{&self.default_pool});

        const fallback_thread = try Thread.spawn(.{}, struct {
            fn run(pool: *HttpPool) void {
                pool.prewarmConnections() catch {};
            }
        }.run, .{&self.fallback_pool});

        default_thread.join();
        fallback_thread.join();
    }

    pub fn processPayment(self: *Self, data: PaymentData, processor_type: config.ProcessorType) !PaymentResult {
        // Serialize payment data to JSON
        var json_buf = std.ArrayList(u8).init(self.allocator);
        defer json_buf.deinit();

        try json.stringify(data, .{}, json_buf.writer());

        // Choose the appropriate pool
        const pool = switch (processor_type) {
            .default => &self.default_pool,
            .fallback => &self.fallback_pool,
        };

        // Make HTTP request
        var response = pool.request("POST", "/payments", json_buf.items) catch |err| {
            std.log.err("HTTP request failed for processor {}: {}", .{ processor_type, err });
            return error.HttpRequestFailed;
        };
        defer response.deinit();

        if (response.status_code != 200) {
            std.log.err("Payment processor {} returned status: {}", .{ processor_type, response.status_code });
            return error.ProcessorUnavailable;
        }

        return PaymentResult{
            .processor = processor_type,
            .data = data,
        };
    }

    pub fn checkHealth(self: *Self, processor_type: config.ProcessorType) !CheckHealthResponse {
        const pool = switch (processor_type) {
            .default => &self.default_pool,
            .fallback => &self.fallback_pool,
        };

        const start_time = std.time.microTimestamp();
        var response = pool.request("GET", "/payments/service-health", null) catch {
            return CheckHealthResponse{
                .failing = true,
                .minResponseTime = 0,
            };
        };
        defer response.deinit();

        const end_time = std.time.microTimestamp();
        const response_time = @as(f64, @floatFromInt(end_time - start_time)) / 1000.0; // Convert to milliseconds

        if (response.status_code == 200) {
            // Try to parse the health response
            var parsed = json.parseFromSlice(CheckHealthResponse, self.allocator, response.body, .{}) catch {
                return CheckHealthResponse{
                    .failing = false,
                    .minResponseTime = response_time,
                };
            };
            defer parsed.deinit();

            var health = parsed.value;
            health.minResponseTime = @min(health.minResponseTime, response_time);
            return health;
        } else {
            return CheckHealthResponse{
                .failing = true,
                .minResponseTime = response_time,
            };
        }
    }

    pub fn processWithDefault(self: *Self, data: PaymentData) !PaymentResult {
        return try self.processPayment(data, .default);
    }

    pub fn processWithFallback(self: *Self, data: PaymentData) !PaymentResult {
        return try self.processPayment(data, .fallback);
    }
};
