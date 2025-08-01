const std = @import("std");
const database = @import("database/connection.zig");
const payments_handler = @import("handlers/payments.zig");
const summary_handler = @import("handlers/summary.zig");

pub fn start(allocator: std.mem.Allocator, db_pool: *database.Pool, port: u16) !void {
    const address = try std.net.Address.parseIp4("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("Server listening on port {}", .{port});

    while (true) {
        const connection = server.accept() catch |err| {
            std.log.err("Failed to accept connection: {}", .{err});
            continue;
        };

        // Handle connection in a separate thread for concurrency
        const thread = std.Thread.spawn(.{}, handleConnection, .{ allocator, db_pool, connection }) catch |err| {
            std.log.err("Failed to spawn thread: {}", .{err});
            connection.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(allocator: std.mem.Allocator, db_pool: *database.Pool, connection: std.net.Server.Connection) void {
    defer connection.stream.close();

    var buffer: [8192]u8 = undefined;
    var http_server = std.http.Server.init(connection, &buffer);

    var request = http_server.receiveHead() catch |err| {
        std.log.err("Failed to receive request: {}", .{err});
        return;
    };

    handleRequest(allocator, db_pool, &request) catch |err| {
        std.log.err("Failed to handle request: {}", .{err});
        _ = request.respond("Internal Server Error", .{
            .status = .internal_server_error,
        }) catch {};
    };
}

fn handleRequest(allocator: std.mem.Allocator, db_pool: *database.Pool, request: *std.http.Server.Request) !void {
    const method = request.head.method;
    const path = request.head.target;

    // Parse path without query parameters
    const clean_path = if (std.mem.indexOf(u8, path, "?")) |query_start|
        path[0..query_start]
    else
        path;

    if (method == .POST and std.mem.eql(u8, clean_path, "/payments")) {
        try payments_handler.handle(allocator, db_pool, request);
    } else if (method == .GET and std.mem.eql(u8, clean_path, "/payments-summary")) {
        try summary_handler.handle(allocator, db_pool, request);
    } else if (method == .GET and std.mem.eql(u8, clean_path, "/health")) {
        try request.respond("{\"status\":\"ok\"}", .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    } else {
        try request.respond("Not Found", .{
            .status = .not_found,
        });
    }
}
