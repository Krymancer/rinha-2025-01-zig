const std = @import("std");

pub const PaymentRequest = struct {
    correlationId: []const u8,
    amount: f64,
};

pub const PaymentProcessorRequest = struct {
    correlationId: []const u8,
    amount: f64,
    requestedAt: []const u8,
};

pub const PaymentResponse = struct {
    message: []const u8,
};

pub const PaymentSummaryResponse = struct {
    default: ProcessorSummary,
    fallback: ProcessorSummary,
};

pub const ProcessorSummary = struct {
    totalRequests: i64,
    totalAmount: f64,
};

pub const PaymentSummaryAll = struct {
    default_total_requests: u32,
    default_total_amount: f64,
    fallback_total_requests: u32,
    fallback_total_amount: f64,
};

pub const PaymentStatus = enum {
    pending,
    processing,
    completed,
    failed,
    fallback_completed,

    pub fn toString(self: PaymentStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .processing => "processing",
            .completed => "completed",
            .failed => "failed",
            .fallback_completed => "fallback_completed",
        };
    }
};

pub const PaymentProcessor = enum {
    default,
    fallback,

    pub fn toString(self: PaymentProcessor) []const u8 {
        return switch (self) {
            .default => "default",
            .fallback => "fallback",
        };
    }
};

pub const Payment = struct {
    id: i64,
    correlation_id: []const u8,
    amount: f64,
    status: PaymentStatus,
    processor: ?PaymentProcessor,
    created_at: []const u8,
    processed_at: ?[]const u8,
    requested_at: ?[]const u8,
};
