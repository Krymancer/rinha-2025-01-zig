const std = @import("std");
const httpz = @import("httpz");
const PaymentService = @import("payment_service.zig");

var payment_service: *PaymentService = undefined;

pub fn setPaymentService(service: *PaymentService) void {
    payment_service = service;
}

pub fn handlePayment(req: *httpz.Request, res: *httpz.Response) !void {
    const allocator = req.arena;

    const body = req.body() orelse {
        res.status = 400;
        try res.json(.{ .@"error" = "Missing request body" }, .{});
        return;
    };

    const payment = PaymentService.PaymentRequest.fromJson(allocator, body) catch |err| {
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

    // Process payment
    payment_service.processPayment(payment) catch |err| {
        std.log.err("Failed to process payment: {}", .{err});
        res.status = 500;
        try res.json(.{ .@"error" = "Payment processing failed" }, .{});
        return;
    };

    // Return success
    res.status = 200;
    try res.json(.{ .message = "Payment processed successfully" }, .{});
}

pub fn handlePaymentsSummary(req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    const from = query.get("from");
    const to = query.get("to");

    const summary = payment_service.getPaymentsSummary(from, to);

    res.status = 200;
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
    res.status = 200;
    try res.json(.{ .status = "healthy" }, .{});
}

pub fn handleNotFound(req: *httpz.Request, res: *httpz.Response) void {
    _ = req;
    res.status = 404;
    res.json(.{ .@"error" = "Endpoint not found" }, .{}) catch {};
}

fn isValidUUID(uuid_str: []const u8) bool {
    if (uuid_str.len != 36) return false;

    if (uuid_str[8] != '-' or uuid_str[13] != '-' or uuid_str[18] != '-' or uuid_str[23] != '-') {
        return false;
    }

    for (uuid_str, 0..) |char, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!std.ascii.isHex(char)) return false;
    }

    return true;
}
