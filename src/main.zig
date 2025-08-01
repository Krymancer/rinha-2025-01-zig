const std = @import("std");
const server = @import("server.zig");
const database = @import("database/connection.zig");
const workers = @import("workers/payment_worker.zig");
const queue_service = @import("services/queue_service.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get environment variables (cross-platform)
    const db_host = std.process.getEnvVarOwned(allocator, "DB_HOST") catch allocator.dupe(u8, "localhost") catch "localhost";
    defer if (!std.mem.eql(u8, db_host, "localhost")) allocator.free(db_host);

    const db_port_str = std.process.getEnvVarOwned(allocator, "DB_PORT") catch allocator.dupe(u8, "5432") catch "5432";
    defer if (!std.mem.eql(u8, db_port_str, "5432")) allocator.free(db_port_str);
    const db_port = try std.fmt.parseInt(u16, db_port_str, 10);

    const server_port_str = std.process.getEnvVarOwned(allocator, "PORT") catch allocator.dupe(u8, "9999") catch "9999";
    defer if (!std.mem.eql(u8, server_port_str, "9999")) allocator.free(server_port_str);
    const server_port = try std.fmt.parseInt(u16, server_port_str, 10);

    // Initialize database connection pool
    var db_pool = try database.Pool.init(allocator, .{
        .host = db_host,
        .port = db_port,
        .database = "payments",
        .username = "postgres",
        .password = "postgres",
        .pool_size = 10,
    });
    defer db_pool.deinit();

    // Initialize database schema
    try database.initSchema(&db_pool);

    std.log.info("Database initialized", .{});

    // Start background workers
    var worker_threads: [2]std.Thread = undefined;
    for (&worker_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workers.run, .{ allocator, &db_pool, i });
    }
    defer for (worker_threads) |thread| thread.join();

    std.log.info("Workers started", .{});

    // Start HTTP server
    try server.start(allocator, &db_pool, server_port);
}
