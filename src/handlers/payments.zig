const std = @import("std");
const database = @import("../database/connection.zig");
const queue_service = @import("../services/queue_service.zig");
const models = @import("../models/payment.zig");

pub fn handle(
    allocator: std.mem.Allocator,
    db_pool: *database.Pool,
    request: *std.http.Server.Request,
) !void {
    // Read and parse request body
    var body_buffer: [4096]u8 = undefined;
    const reader = try request.reader();
    const bytes_read = try reader.read(&body_buffer);
    const body = body_buffer[0..bytes_read];

    // Parse JSON
    const parsed = std.json.parseFromSlice(models.PaymentRequest, allocator, body, .{}) catch |err| {
        std.log.err("Failed to parse JSON: {any}", .{err});
        return request.respond("{\"error\":\"Invalid JSON format\"}", .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    };
    defer parsed.deinit();

    const payment_request = parsed.value;

    // Validate UUID format
    if (!isValidUUID(payment_request.correlationId)) {
        return request.respond("{\"error\":\"Invalid correlation ID format\"}", .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }

    // Validate amount
    if (payment_request.amount <= 0) {
        return request.respond("{\"error\":\"Amount must be positive\"}", .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }

    // Check if payment already exists
    if (db_pool.paymentExists(payment_request.correlationId) catch false) {
        return request.respond("{\"error\":\"Payment with this correlation ID already exists\"}", .{
            .status = .conflict,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }

    // Create payment record
    const payment = models.Payment{
        .id = 0, // Will be set by database
        .correlation_id = payment_request.correlationId,
        .amount = payment_request.amount,
        .status = .pending,
        .processor = null,
        .created_at = "", // Will be set by database
        .processed_at = null,
        .requested_at = null,
    };

    // Insert payment into database
    const payment_id = db_pool.insertPayment(payment) catch |err| {
        std.log.err("Failed to insert payment: {any}", .{err});
        return request.respond("{\"error\":\"Failed to store payment\"}", .{
            .status = .internal_server_error,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    };

    std.log.info("Payment stored with ID {}: {s} for amount {d}", .{ payment_id, payment_request.correlationId, payment_request.amount });

    // Enqueue for processing
    queue_service.enqueuePayment(allocator, payment_request.correlationId) catch |err| {
        std.log.err("Failed to enqueue payment: {any}", .{err});
        return request.respond("{\"error\":\"Failed to enqueue payment\"}", .{
            .status = .internal_server_error,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    };

    // Return success response
    return request.respond("{\"status\":\"accepted\"}", .{
        .status = .accepted,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn isValidUUID(str: []const u8) bool {
    if (str.len != 36) return false;

    // Check format: 8-4-4-4-12
    if (str[8] != '-' or str[13] != '-' or str[18] != '-' or str[23] != '-') {
        return false;
    }

    // Check hex characters
    for (str, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue; // Skip dashes
        if (!std.ascii.isHex(c)) return false;
    }

    return true;
}
