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

    var payment_service = PaymentService.init(allocator, &config);
    defer payment_service.deinit();

    RouteHandler.setPaymentService(&payment_service);

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

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
