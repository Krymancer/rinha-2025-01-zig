const std = @import("std");
const net = std.net;
const json = std.json;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const State = @import("state.zig").State;
const Queue = @import("queue.zig").Queue;
const QueueMessage = @import("queue.zig").QueueMessage;
const config = @import("config.zig");
const money = @import("money.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub const Server = struct {
    const Self = @This();

    allocator: Allocator,
    state: *State,
    queue: *Queue,
    config: *const config.Config,

    pub fn init(allocator: Allocator, state: *State, queue: *Queue, app_config: *const config.Config) !Self {
        return Self{
            .allocator = allocator,
            .state = state,
            .queue = queue,
            .config = app_config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn listen(self: *Self, socket_path: []const u8) !void {
        const address = try net.Address.initUnix(socket_path);
        var listener = try net.Address.listen(address, .{
            .reuse_address = true,
        });
        defer listener.deinit();

        // Set socket permissions using chmod system call
        const socket_path_z = try self.allocator.dupeZ(u8, socket_path);
        defer self.allocator.free(socket_path_z);
        const result = std.c.chmod(socket_path_z.ptr, 0o666);

        if (result != 0) {
            std.log.err("Failed to chmod socket {s}: {d}", .{ socket_path, result });
        } else {
            std.log.info("Successfully set permissions for socket {s}", .{socket_path});
        }

        std.log.info("Server listening on: {s}", .{socket_path});

        while (true) {
            const connection = listener.accept() catch |err| {
                std.log.err("Failed to accept connection: {}", .{err});
                continue;
            };
            // Handle request in a separate thread
            const thread = try Thread.spawn(.{}, handleConnection, .{ self, connection });
            thread.detach();
        }

        std.log.info("Server stopped listening on: {s}", .{socket_path});
    }

    fn handleConnection(self: *Self, connection: net.Server.Connection) void {
        defer connection.stream.close();

        self.handleConnectionInner(connection) catch |err| {
            std.log.err("Error handling connection: {}", .{err});
        };
    }

    fn handleConnectionInner(self: *Self, connection: net.Server.Connection) !void {
        var buffer: [4096]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);

        if (bytes_read == 0) return;

        const request_data = buffer[0..bytes_read];

        // Simple HTTP request parsing
        var lines = std.mem.splitSequence(u8, request_data, "\r\n");
        const first_line = lines.next() orelse return;

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        std.log.info("Received request: {s} {s}", .{ method, path });

        // Route requests
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/payments")) {
            try self.handlePayments(connection, request_data);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/payments-summary")) {
            try self.handlePaymentsSummary(connection, path);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/purge-payments")) {
            try self.handlePurgePayments(connection);
        } else {
            try self.sendResponse(connection, "404 Not Found", "");
        }
    }

    fn handlePayments(self: *Self, connection: net.Server.Connection, request_data: []const u8) !void {
        // Find the request body (after \r\n\r\n)
        const body_start = std.mem.indexOf(u8, request_data, "\r\n\r\n");
        if (body_start == null) {
            try self.sendResponse(connection, "400 Bad Request", "");
            return;
        }

        const body = request_data[body_start.? + 4 ..];

        // Parse JSON
        var parsed = json.parseFromSlice(QueueMessage, self.allocator, body, .{}) catch {
            try self.sendResponse(connection, "400 Bad Request", "");
            return;
        };
        defer parsed.deinit();

        const message = parsed.value;

        // Validate message
        if (message.amount <= 0 or message.correlation_id.len == 0) {
            try self.sendResponse(connection, "400 Bad Request", "");
            return;
        }

        // Enqueue message
        self.queue.enqueue(message.amount, message.correlation_id) catch {
            try self.sendResponse(connection, "500 Internal Server Error", "");
            return;
        };

        // Send OK response
        try self.sendResponse(connection, "200 OK", "");
    }

    fn handlePaymentsSummary(self: *Self, connection: net.Server.Connection, path: []const u8) !void {
        // Parse query parameters
        var from: ?[]const u8 = null;
        var to: ?[]const u8 = null;
        var local_only = false;

        if (std.mem.indexOf(u8, path, "?")) |query_start| {
            const query = path[query_start + 1 ..];
            var params = std.mem.splitScalar(u8, query, '&');
            while (params.next()) |param| {
                var kv = std.mem.splitScalar(u8, param, '=');
                const key = kv.next() orelse continue;
                const value = kv.next() orelse continue;

                if (std.mem.eql(u8, key, "from")) {
                    from = value;
                } else if (std.mem.eql(u8, key, "to")) {
                    to = value;
                } else if (std.mem.eql(u8, key, "localOnly")) {
                    local_only = std.mem.eql(u8, value, "true");
                }
            }
        }

        std.log.info("Handling payments summary: from={s}, to={s}, local_only={}", .{
            if (from) |f| f else "null",
            if (to) |t| t else "null",
            local_only,
        });

        // Get payment summary
        const summary = try self.getPaymentSummary(from, to, local_only);

        // Serialize to JSON
        var json_buf = std.ArrayList(u8).init(self.allocator);
        defer json_buf.deinit();

        try json.stringify(summary, .{}, json_buf.writer());

        // Send JSON response
        try self.sendJsonResponse(connection, json_buf.items);
    }

    fn handlePurgePayments(self: *Self, connection: net.Server.Connection) !void {
        self.state.default.reset();
        self.state.fallback.reset();
        try self.sendResponse(connection, "200 OK", "");
    }

    fn getPaymentSummary(self: *Self, from: ?[]const u8, to: ?[]const u8, local_only: bool) !PaymentSummaryResponse {
        // Get local state
        const default_entries = try self.state.default.list(self.allocator);
        defer self.allocator.free(default_entries);

        const fallback_entries = try self.state.fallback.list(self.allocator);
        defer self.allocator.free(fallback_entries);

        // Parse timestamps
        const from_ts = if (from) |f| parseTimestamp(f) else null;
        const to_ts = if (to) |t| parseTimestamp(t) else null;

        // Process local state
        var local_summary = PaymentSummaryResponse{
            .default = processEntries(default_entries, from_ts, to_ts),
            .fallback = processEntries(fallback_entries, from_ts, to_ts),
        };

        // If not local_only, fetch foreign state
        if (!local_only and self.config.foreign_state.len > 0) {
            const foreign_summary = try self.getForeignSummary(from, to);
            local_summary.default.totalAmount += foreign_summary.default.totalAmount;
            local_summary.default.totalRequests += foreign_summary.default.totalRequests;
            local_summary.fallback.totalAmount += foreign_summary.fallback.totalAmount;
            local_summary.fallback.totalRequests += foreign_summary.fallback.totalRequests;
        }

        return local_summary;
    }

    fn getForeignSummary(self: *Self, from: ?[]const u8, to: ?[]const u8) !PaymentSummaryResponse {
        // Build URL with query parameters
        var url_buf: [512]u8 = undefined;
        var url = try std.fmt.bufPrint(&url_buf, "http://nginx:9999/{s}/payments-summary?localOnly=true", .{self.config.foreign_state});

        if (from) |f| {
            const new_url = try std.fmt.bufPrint(&url_buf, "{s}&from={s}", .{ url, f });
            url = new_url;
        }
        if (to) |t| {
            const new_url = try std.fmt.bufPrint(&url_buf, "{s}&to={s}", .{ url, t });
            url = new_url;
        }

        // Parse URL to extract host and path
        const url_without_protocol = if (std.mem.startsWith(u8, url, "http://"))
            url[7..]
        else
            url;

        const slash_pos = std.mem.indexOf(u8, url_without_protocol, "/") orelse url_without_protocol.len;
        const host_port = url_without_protocol[0..slash_pos];
        const path = if (slash_pos < url_without_protocol.len) url_without_protocol[slash_pos..] else "/";

        // Parse host and port
        var host_parts = std.mem.splitScalar(u8, host_port, ':');
        const host = host_parts.next() orelse "nginx";
        const port_str = host_parts.next() orelse "9999";
        const port = std.fmt.parseInt(u16, port_str, 10) catch 9999;

        // Make HTTP request
        const address = if (std.mem.eql(u8, host, "nginx"))
            net.Address.parseIp("127.0.0.1", port) catch {
                // Return empty summary on DNS failure
                return PaymentSummaryResponse{
                    .default = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                    .fallback = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                };
            }
        else
            net.Address.parseIp(host, port) catch {
                // Return empty summary on DNS failure
                return PaymentSummaryResponse{
                    .default = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                    .fallback = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                };
            };

        const stream = net.tcpConnectToAddress(address) catch {
            // Return empty summary on connection failure
            return PaymentSummaryResponse{
                .default = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                .fallback = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
            };
        };
        defer stream.close();

        // Build HTTP GET request
        var request_buf = std.ArrayList(u8).init(self.allocator);
        defer request_buf.deinit();

        try request_buf.writer().print("GET {s} HTTP/1.1\r\n", .{path});
        try request_buf.writer().print("Host: {s}:{d}\r\n", .{ host, port });
        try request_buf.writer().print("Connection: close\r\n", .{});
        try request_buf.writer().print("\r\n", .{});

        // Send request
        stream.writeAll(request_buf.items) catch {
            return PaymentSummaryResponse{
                .default = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                .fallback = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
            };
        };

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
        const header_end = std.mem.indexOf(u8, response_data, "\r\n\r\n") orelse {
            return PaymentSummaryResponse{
                .default = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                .fallback = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
            };
        };

        const headers = response_data[0..header_end];
        const body_start = header_end + 4;

        // Check status code
        const first_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse {
            return PaymentSummaryResponse{
                .default = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                .fallback = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
            };
        };

        const first_line = headers[0..first_line_end];
        var status_parts = std.mem.splitScalar(u8, first_line, ' ');
        _ = status_parts.next(); // Skip HTTP version
        const status_str = status_parts.next() orelse {
            return PaymentSummaryResponse{
                .default = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                .fallback = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
            };
        };

        const status_code = std.fmt.parseInt(u16, status_str, 10) catch {
            return PaymentSummaryResponse{
                .default = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                .fallback = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
            };
        };

        if (status_code != 200) {
            return PaymentSummaryResponse{
                .default = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                .fallback = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
            };
        }

        // Parse JSON response body
        const response_body = response_data[body_start..];
        var parsed = json.parseFromSlice(PaymentSummaryResponse, self.allocator, response_body, .{}) catch {
            std.log.err("Failed to parse foreign payment summary: {s}", .{response_body});
            return PaymentSummaryResponse{
                .default = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
                .fallback = PaymentSummary{ .totalRequests = 0, .totalAmount = 0 },
            };
        };
        defer parsed.deinit();

        return parsed.value;
    }

    fn sendResponse(self: *Self, connection: net.Server.Connection, status: []const u8, body: []const u8) !void {
        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, body.len, body });
        defer self.allocator.free(response);

        _ = try connection.stream.writeAll(response);
    }

    fn sendJsonResponse(self: *Self, connection: net.Server.Connection, json_body: []const u8) !void {
        try self.sendResponse(connection, "200 OK", json_body);
    }
};

const PaymentSummary = struct {
    totalRequests: u32,
    totalAmount: f64,
};

const PaymentSummaryResponse = struct {
    default: PaymentSummary,
    fallback: PaymentSummary,
};

fn parseTimestamp(date_str: []const u8) ?i64 {
    // Simple timestamp parsing - you might want to use a proper date parser
    const timestamp = std.fmt.parseInt(i64, date_str, 10) catch return null;
    return timestamp;
}

fn processEntries(entries: []const @import("state.zig").StorageEntry, from_ts: ?i64, to_ts: ?i64) PaymentSummary {
    var summary = PaymentSummary{
        .totalRequests = 0,
        .totalAmount = 0,
    };

    for (entries) |entry| {
        // Check timestamp range
        if (from_ts) |from| {
            if (entry.requested_at < from) continue;
        }
        if (to_ts) |to| {
            if (entry.requested_at > to) continue;
        }

        summary.totalRequests += 1;
        summary.totalAmount += money.centsToFloat(entry.amount);
    }

    return summary;
}
