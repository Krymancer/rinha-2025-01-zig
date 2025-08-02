const std = @import("std");
const database = @import("../database/connection.zig");
const queue_service = @import("../services/queue_service.zig");
const processor_client = @import("../services/processor_client.zig");
const models = @import("../models/payment.zig");

pub fn run(allocator: std.mem.Allocator, db_pool: *database.Pool, worker_id: usize) !void {
    std.log.info("Worker {any} started", .{worker_id});
    var client = processor_client.ProcessorClient.init(allocator, .{});
    defer client.deinit();

    while (true) {
        if (queue_service.dequeuePayment(allocator)) |correlation_id| {
            defer allocator.free(correlation_id);

            std.log.info("Worker {any}: Processing payment {s}", .{ worker_id, correlation_id });
            db_pool.updatePaymentStatus(correlation_id, .processing, null) catch |err| {
                std.log.err("Worker {any}: Failed to update payment status to processing: {any}", .{ worker_id, err });
                continue;
            };
            const payment = db_pool.getPayment(correlation_id) catch |err| {
                std.log.err("Worker {any}: Failed to get payment details: {any}", .{ worker_id, err });
                continue;
            };

            if (payment == null) {
                std.log.err("Worker {any}: Payment not found: {s}", .{ worker_id, correlation_id });
                continue;
            }

            const payment_data = payment.?;
            const processor_request = models.PaymentProcessorRequest{
                .correlationId = correlation_id,
                .amount = payment_data.amount,
                .requestedAt = try processor_client.formatTimestamp(allocator),
            };
            defer allocator.free(processor_request.requestedAt);
            var success = false;
            var used_processor: models.PaymentProcessor = .default;
            const default_health = client.checkHealth(.default) catch |err| blk: {
                std.log.warn("Worker {any}: Default processor health check failed: {any}", .{ worker_id, err });
                break :blk processor_client.HealthStatus{ .failing = true, .minResponseTime = 9999 };
            };

            if (!default_health.failing) {
                if (client.processPayment(processor_request, .default)) |result| {
                    defer allocator.free(result.message);
                    success = true;
                    used_processor = .default;
                    std.log.info("Worker {any}: Payment processed successfully with default processor", .{worker_id});
                } else |err| {
                    std.log.warn("Worker {any}: Default processor failed: {any}", .{ worker_id, err });
                }
            }
            if (!success) {
                std.log.info("Worker {any}: Trying fallback processor for payment {s}", .{ worker_id, correlation_id });

                const fallback_health = client.checkHealth(.fallback) catch |err| blk: {
                    std.log.warn("Worker {any}: Fallback processor health check failed: {any}", .{ worker_id, err });
                    break :blk processor_client.HealthStatus{ .failing = true, .minResponseTime = 9999 };
                };

                if (!fallback_health.failing) {
                    if (client.processPayment(processor_request, .fallback)) |result| {
                        defer allocator.free(result.message);
                        success = true;
                        used_processor = .fallback;
                        std.log.info("Worker {any}: Payment processed successfully with fallback processor", .{worker_id});
                    } else |err| {
                        std.log.err("Worker {any}: Fallback processor also failed: {any}", .{ worker_id, err });
                    }
                }
            }
            if (success) {
                const final_status: models.PaymentStatus = if (used_processor == .fallback) .fallback_completed else .completed;
                db_pool.updatePaymentStatus(correlation_id, final_status, used_processor) catch |err| {
                    std.log.err("Worker {any}: Failed to update payment status to completed: {any}", .{ worker_id, err });
                };
                std.log.info("Worker {any}: Completed payment {s} with processor", .{ worker_id, correlation_id });
            } else {
                db_pool.updatePaymentStatus(correlation_id, .failed, null) catch |err| {
                    std.log.err("Worker {any}: Failed to update payment status to failed: {any}", .{ worker_id, err });
                };
                std.log.err("Worker {any}: Failed to process payment {s} - both processors unavailable", .{ worker_id, correlation_id });
            }
        } else {
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }
}
