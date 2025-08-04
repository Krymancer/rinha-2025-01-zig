const std = @import("std");
const net = std.net;
const http = std.http;
const json = std.json;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const config = @import("config/env.zig");
const Server = @import("server.zig").Server;
const State = @import("shared/state.zig").State;
// const Queue = @import("queue.zig").Queue;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting application", .{});

    // Initialize configuration
    var app_config = try config.Config.init(allocator);
    defer app_config.deinit();

    std.log.info("Configuration loaded: fire_mode={}", .{app_config.is_fire_mode});

    // Initialize global state
    var state = State.init(allocator);
    defer state.deinit();

    std.log.info("State initialized", .{});

    // Initialize processing queue (heap-allocated to ensure stable memory location)
    // var queue = try allocator.create(Queue);
    // queue.* = try Queue.init(allocator, &state, .{
    //     .workers = 1,
    //     .is_fire_mode = app_config.is_fire_mode,
    // });
    // defer {
    //     queue.deinit();
    //     allocator.destroy(queue);
    // }

    std.log.info("Queue disabled - using direct workers", .{});

    // Start HTTP server
    var server = try Server.init(allocator, &state, null, &app_config);
    defer server.deinit();

    std.log.info("Server initialized", .{});

    std.log.info("Server starting on socket: {s}", .{app_config.socket_path});
    server.listen(app_config.socket_path) catch |err| {
        std.log.err("Failed to start server: {any}", .{err});
        return err;
    };
}
