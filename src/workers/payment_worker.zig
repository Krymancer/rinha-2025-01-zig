const std = @import("std");
const database = @import("../database/connection.zig");
const queue_service = @import("../services/queue_service.zig");
const processor_client = @import("../services/processor_client.zig");
const models = @import("../models/payment.zig");

pub fn run(allocator: std.mem.Allocator, db_pool: *database.Pool, worker_id: usize) !void {
    std.log.info("Worker {} started", .{worker_id});

    // Initialize processor client
    var client = processor_client.ProcessorClient.init(allocator, .{});
    defer client.deinit();

    while (true) {
        // Dequeue payment for processing
        if (queue_service.dequeuePayment(allocator)) |correlation_id| {
            defer allocator.free(correlation_id);

            std.log.info("Worker {}: Processing payment {s}", .{ worker_id, correlation_id });

            // Update payment status to processing
            db_pool.updatePaymentStatus(correlation_id, .processing, null) catch |err| {
                std.log.err("Worker {}: Failed to update payment status to processing: {any}", .{ worker_id, err });
                continue;
            };

            // Get payment details from database
            const payment = db_pool.getPayment(correlation_id) catch |err| {
                std.log.err("Worker {}: Failed to get payment details: {any}", .{ worker_id, err });
                continue;
            };

            if (payment == null) {
                std.log.err("Worker {}: Payment not found: {s}", .{ worker_id, correlation_id });
                continue;
            }

            const payment_data = payment.?;

            // Create processor request
            const processor_request = models.PaymentProcessorRequest{
                .correlationId = correlation_id,
                .amount = payment_data.amount,
                .requestedAt = try processor_client.formatTimestamp(allocator),
            };
            defer allocator.free(processor_request.requestedAt);

            // Try default processor first
            var success = false;
            var used_processor: models.PaymentProcessor = .default;

            // Check default processor health
            const default_health = client.checkHealth(.default) catch |err| blk: {
                std.log.warn("Worker {}: Default processor health check failed: {any}", .{ worker_id, err });
                break :blk processor_client.HealthStatus{ .failing = true, .minResponseTime = 9999 };
            };

            if (!default_health.failing) {
                // Try processing with default processor
                if (client.processPayment(processor_request, .default)) |result| {
                    defer allocator.free(result.message);
                    success = true;
                    used_processor = .default;
                    std.log.info("Worker {}: Payment processed successfully with default processor", .{worker_id});
                } else |err| {
                    std.log.warn("Worker {}: Default processor failed: {any}", .{ worker_id, err });
                }
            }

            // If default failed, try fallback
            if (!success) {
                std.log.info("Worker {}: Trying fallback processor for payment {s}", .{ worker_id, correlation_id });

                const fallback_health = client.checkHealth(.fallback) catch |err| blk: {
                    std.log.warn("Worker {}: Fallback processor health check failed: {any}", .{ worker_id, err });
                    break :blk processor_client.HealthStatus{ .failing = true, .minResponseTime = 9999 };
                };

                if (!fallback_health.failing) {
                    if (client.processPayment(processor_request, .fallback)) |result| {
                        defer allocator.free(result.message);
                        success = true;
                        used_processor = .fallback;
                        std.log.info("Worker {}: Payment processed successfully with fallback processor", .{worker_id});
                    } else |err| {
                        std.log.err("Worker {}: Fallback processor also failed: {any}", .{ worker_id, err });
                    }
                }
            }

            // Update payment status based on result
            if (success) {
                const final_status: models.PaymentStatus = if (used_processor == .fallback) .fallback_completed else .completed;
                db_pool.updatePaymentStatus(correlation_id, final_status, used_processor) catch |err| {
                    std.log.err("Worker {}: Failed to update payment status to completed: {any}", .{ worker_id, err });
                };
                std.log.info("Worker {}: Completed payment {s} with processor {s}", .{ worker_id, correlation_id, used_processor.toString() });
            } else {
                db_pool.updatePaymentStatus(correlation_id, .failed, null) catch |err| {
                    std.log.err("Worker {}: Failed to update payment status to failed: {any}", .{ worker_id, err });
                };
                std.log.err("Worker {}: Failed to process payment {s} - both processors unavailable", .{ worker_id, correlation_id });
            }
        } else {
            // No payments to process, sleep a bit
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }
}
