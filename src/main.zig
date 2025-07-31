const std = @import("std");
const httpz = @import("httpz");
const Config = @import("config.zig").Config;
const RouteHandler = @import("routes.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config.init(allocator) catch |err| {
        std.log.err("Failed to load configuration: {}", .{err});
        return;
    };

    var server = httpz.Server(void).init(allocator, .{
        .port = config.port,
        .address = config.address,
    }, {}) catch |err| {
        std.log.err("Failed to initialize server: {}", .{err});
        return;
    };
    defer server.deinit();

    var router = try server.router(.{});

    router.post("/payments", RouteHandler.handlePayment, .{});
    router.get("/payments-summary", RouteHandler.handlePaymentsSummary, .{});
    router.get("/health", RouteHandler.handleHealth, .{});

    std.log.info("Starting server on {s}:{}", .{ config.address, config.port });
    try server.listen();
}
