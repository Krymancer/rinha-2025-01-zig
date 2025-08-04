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
    const summary = self.getPaymentSummary(from, to, local_only) catch |err| {
        std.log.err("Failed to get payment summary: {}", .{err});
        try self.sendResponse(connection, "500 Internal Server Error", "");
        return;
    };

    // Serialize to JSON
    var json_buf = std.ArrayList(u8).init(self.allocator);
    defer json_buf.deinit();

    try json.stringify(summary, .{}, json_buf.writer());

    // Send JSON response
    try self.sendJsonResponse(connection, json_buf.items);
}

fn getPaymentSummary(self: *Self, from: ?[]const u8, to: ?[]const u8, local_only: bool) !PaymentSummaryResponse {
    std.log.info("Getting payment summary: from={s}, to={s}, local_only={}", .{
        if (from) |f| f else "null",
        if (to) |t| t else "null",
        local_only,
    });

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
