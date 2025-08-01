const std = @import("std");
const database = @import("../database/connection.zig");
const queue_service = @import("../services/queue_service.zig");
const models = @import("../models/payment.zig");

pub fn run(allocator: std.mem.Allocator, db_pool: *database.Pool, worker_id: usize) !void {
    std.log.info("Worker {} started", .{worker_id});
    _ = db_pool;

    while (true) {
        // Dequeue payment for processing
        if (queue_service.dequeuePayment(allocator)) |correlation_id| {
            defer allocator.free(correlation_id);

            std.log.info("Worker {}: Processing payment {s}", .{ worker_id, correlation_id });

            // Simulate processing time
            std.time.sleep(100 * std.time.ns_per_ms);

            std.log.info("Worker {}: Completed payment {s}", .{ worker_id, correlation_id });
        } else {
            // No payments to process, sleep a bit
            std.time.sleep(50 * std.time.ns_per_ms);
        }
    }
}
