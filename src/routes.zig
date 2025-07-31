const std = @import("std");
const httpz = @import("httpz");
const PaymentService = @import("payment_service.zig").PaymentService;
const PaymentRequest = @import("payment_service.zig").PaymentRequest;

var async_payment_service: *PaymentService = undefined;

pub fn setAsyncPaymentService(service: *PaymentService) void {
    async_payment_service = service;
}

pub fn handlePayment(req: *httpz.Request, res: *httpz.Response) !void {
    const allocator = req.arena;

    const body = req.body() orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "Missing request body" }, .{});
        return;
    };

    const payment = PaymentRequest.fromJson(allocator, body) catch |err| {
        std.log.err("Failed to parse payment request: {}", .{err});
        res.status = 400;
        try res.json(.{ .@"error" = "Invalid request format" }, .{});
        return;
    };

    if (!isValidUUID(payment.correlationId)) {
        res.status = 400;
        try res.json(.{ .@"error" = "Invalid correlationId format" }, .{});
        return;
    }

    if (payment.amount <= 0) {
        res.status = 400;
        try res.json(.{ .@"error" = "Amount must be positive" }, .{});
        return;
    }

    // Submit to queue for async processing
    async_payment_service.submitPayment(payment) catch |err| {
        std.log.err("Failed to queue payment: {}", .{err});
        res.status = 500;
        try res.json(.{ .@"error" = "Payment queue is full" }, .{});
        return;
    };

    // Return immediately (async processing)
    res.status = 202; // Accepted
    try res.json(.{ .message = "Payment queued for processing" }, .{});
}

pub fn handlePaymentsSummary(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;

    const summary = async_payment_service.getPaymentsSummary(null, null);

    try res.json(.{
        .default = .{
            .totalRequests = summary.default.totalRequests,
            .totalAmount = summary.default.totalAmount,
        },
        .fallback = .{
            .totalRequests = summary.fallback.totalRequests,
            .totalAmount = summary.fallback.totalAmount,
        },
    }, .{});
}

pub fn handleHealth(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;

    const health = async_payment_service.getHealthStatus();

    try res.json(.{
        .status = "healthy",
        .processors = .{
            .default = .{
                .failing = health.default_failing,
            },
            .fallback = .{
                .failing = health.fallback_failing,
            },
        },
        .queues = .{
            .pending = health.queue_size,
            .failed = health.failed_queue_size,
        },
    }, .{});
}

fn isValidUUID(uuid_str: []const u8) bool {
    if (uuid_str.len != 36) return false;

    const positions = [_]usize{ 8, 13, 18, 23 };
    for (positions) |pos| {
        if (uuid_str[pos] != '-') return false;
    }

    for (uuid_str, 0..) |char, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!std.ascii.isHex(char)) return false;
    }

    return true;
}
