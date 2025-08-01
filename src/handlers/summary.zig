const std = @import("std");
const database = @import("../database/connection.zig");
const models = @import("../models/payment.zig");

pub fn handle(
    allocator: std.mem.Allocator,
    db_pool: *database.Pool,
    request: *std.http.Server.Request,
) !void {
    // Parse query parameters for date filtering
    const target = request.head.target;
    var from_date: ?[]const u8 = null;
    var to_date: ?[]const u8 = null;

    // Simple query parameter parsing
    if (std.mem.indexOf(u8, target, "?")) |query_start| {
        const query_string = target[query_start + 1 ..];
        var params = std.mem.splitSequence(u8, query_string, "&");

        while (params.next()) |param| {
            if (std.mem.startsWith(u8, param, "from=")) {
                from_date = param[5..];
            } else if (std.mem.startsWith(u8, param, "to=")) {
                to_date = param[3..];
            }
        }
    }

    // Get summaries from database
    const default_summary = db_pool.getPaymentSummary(.default, from_date, to_date) catch |err| {
        std.log.err("Failed to get default processor summary: {any}", .{err});
        return request.respond("{\"error\":\"Failed to retrieve payment summary\"}", .{
            .status = .internal_server_error,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    };

    const fallback_summary = db_pool.getPaymentSummary(.fallback, from_date, to_date) catch |err| {
        std.log.err("Failed to get fallback processor summary: {any}", .{err});
        return request.respond("{\"error\":\"Failed to retrieve payment summary\"}", .{
            .status = .internal_server_error,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    };

    // Build JSON response
    const response = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "default": {{
        \\    "totalRequests": {},
        \\    "totalAmount": {d}
        \\  }},
        \\  "fallback": {{
        \\    "totalRequests": {},
        \\    "totalAmount": {d}
        \\  }}
        \\}}
    , .{ default_summary.totalRequests, default_summary.totalAmount, fallback_summary.totalRequests, fallback_summary.totalAmount });
    defer allocator.free(response);

    return request.respond(response, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}
