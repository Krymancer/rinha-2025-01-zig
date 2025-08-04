fn handlePayments(self: *Self, connection: net.Server.Connection, request_data: []const u8) !void {
    std.log.info("Handling payments request", .{});
    const body_start = std.mem.indexOf(u8, request_data, "\r\n\r\n");
    if (body_start == null) {
        std.log.err("Invalid request: no body found", .{});
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
        std.log.err("Invalid payment request: amount={}, correlation_id={s}", .{ message.amount, message.correlation_id });
        try self.sendResponse(connection, "400 Bad Request", "");
        return;
    }

    // Skip queue - spawn worker thread directly
    const correlation_id_copy = try self.allocator.dupe(u8, message.correlation_id);

    const worker_data = try self.allocator.create(DirectWorkerData);
    worker_data.* = DirectWorkerData{
        .server = self,
        .amount = message.amount,
        .correlation_id = correlation_id_copy,
        .allocator = self.allocator,
    };

    const thread = try Thread.spawn(.{}, processPaymentDirectly, .{worker_data});
    thread.detach();

    std.log.info("Spawned direct worker for payment: amount={}, correlation_id={s}", .{ message.amount, message.correlation_id });

    // Send OK response immediately
    try self.sendResponse(connection, "200 OK", "");
}
