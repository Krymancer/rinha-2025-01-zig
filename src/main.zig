const std = @import("std");
const httpz = @import("httpz");
const print = std.debug.print;

const PaymentService = @import("payment_service.zig").PaymentService;
const Config = @import("config.zig").Config;
const RouteHandler = @import("routes.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config.load() catch |err| {
        std.log.err("Failed to load configuration: {}", .{err});
        return;
    };

    // Create async payment service
    var async_payment_service = PaymentService.init(allocator, &config) catch |err| {
        std.log.err("Failed to initialize async payment service: {}", .{err});
        return;
    };
    defer async_payment_service.deinit();

    // Start background workers and health monitoring
    async_payment_service.start() catch |err| {
        std.log.err("Failed to start async payment service: {}", .{err});
        return;
    };

    RouteHandler.setAsyncPaymentService(async_payment_service);

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

    std.log.info("Starting async server on {s}:{}", .{ config.address, config.port });
    std.log.info("Features: queue-based processing, background health monitoring, circuit breaker", .{});

    // Note: Signal handling is platform-specific, this is a basic example
    // In production, you might want to use proper signal handling libraries

    try server.listen();
}
