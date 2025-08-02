const std = @import("std");
const models = @import("../models/payment.zig");
const repository = @import("repository.zig");
pub const Config = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    username: []const u8,
    password: []const u8,
    pool_size: u16 = 10,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    pg_pool: repository.Pool,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Pool {
        std.log.info("Initializing database pool for {s}:{any}", .{ config.host, config.port });

        const pg_pool = repository.Pool.init(
            allocator,
            config.host,
            config.port,
            config.database,
            config.username,
            config.password,
        );

        return Pool{
            .allocator = allocator,
            .config = config,
            .pg_pool = pg_pool,
        };
    }

    pub fn deinit(self: *Pool) void {
        std.log.info("Closing database pool", .{});
        self.pg_pool.deinit();
    }

    pub fn testConnection(self: *Pool) !bool {
        return self.pg_pool.testConnection();
    }
    pub fn insertPayment(self: *Pool, payment: models.Payment) ![]const u8 {
        const result = try self.pg_pool.insertPayment(payment);

        std.log.info("DB: Inserted payment {s} with amount {d}", .{ payment.correlation_id, payment.amount });
        return result;
    }
    pub fn updatePaymentStatus(self: *Pool, correlation_id: []const u8, status: models.PaymentStatus, processor: ?models.PaymentProcessor) !void {
        try self.pg_pool.updatePaymentStatus(correlation_id, status, processor);

        const proc_str = if (processor) |p| p.toString() else "null";
        std.log.info("DB: Updated payment {s} to status {s} with processor {s}", .{ correlation_id, @tagName(status), proc_str });
    }
    pub fn paymentExists(self: *Pool, correlation_id: []const u8) !bool {
        const exists = try self.pg_pool.paymentExists(correlation_id);
        std.log.info("DB: Payment {s} exists: {any}", .{ correlation_id, exists });
        return exists;
    }
    pub fn getPayment(self: *Pool, correlation_id: []const u8) !?models.Payment {
        const payment = try self.pg_pool.getPayment(correlation_id);
        std.log.info("DB: Retrieved payment {s}", .{correlation_id});
        return payment;
    }
    pub fn getPaymentSummary(self: *Pool, from_date: ?[]const u8, to_date: ?[]const u8) !models.PaymentSummaryAll {
        const summary = try self.pg_pool.getPaymentSummary(from_date, to_date);
        std.log.info("DB: Retrieved payment summary", .{});
        return summary;
    }
};

pub fn initSchema(pool: *Pool) !void {
    _ = pool;
    std.log.info("Database schema already initialized via init.sql", .{});
}
