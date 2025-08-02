const std = @import("std");
const payments = @import("handlers/payments.zig");
const summary = @import("handlers/summary.zig");
const database = @import("database/connection.zig");

pub fn handleRequest(
    allocator: std.mem.Allocator,
    db_pool: *database.Pool,
    request: *std.http.Server.Request,
) !void {
    const method = request.head.method;
    const target = request.head.target;
    if (method == .POST and std.mem.eql(u8, target, "/payments")) {
        return payments.handle(allocator, db_pool, request);
    } else if (method == .GET and std.mem.startsWith(u8, target, "/payments-summary")) {
        return summary.handle(allocator, db_pool, request);
    } else {
        return request.respond("Not Found", .{ .status = .not_found });
    }
}
