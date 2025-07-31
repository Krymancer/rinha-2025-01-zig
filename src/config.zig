const std = @import("std");

pub const Config = struct {
    port: u16,
    address: []const u8,
    payment_processor_default_url: []const u8,
    payment_processor_fallback_url: []const u8,
    health_check_interval: u64,
    max_retries: u32,
    timeout_ms: u64,

    pub fn load() !Config {
        return .{
            .port = 8080,
            .address = "0.0.0.0",
            .payment_processor_default_url = "http://payment-processor-default:8080/payments",
            .payment_processor_fallback_url = "http://payment-processor-fallback:8080/payments",
            .health_check_interval = 1, // More frequent health checks
            .max_retries = 1, // Simplified retry logic
            .timeout_ms = 2000, // Shorter timeout
        };
    }
};
