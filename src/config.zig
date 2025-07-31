const std = @import("std");
const dotenv = @import("dotenv");

pub const Config = struct {
    port: u16,
    address: []const u8,
    payment_processor_default_url: []const u8,
    payment_processor_fallback_url: []const u8,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        var envs = try dotenv.getDataFrom(allocator, ".env");
        var it = envs.iterator();

        while (it.next()) |*entry| {
            std.debug.print(
                "{s}={s}\n",
                .{ entry.key_ptr.*, entry.value_ptr.*.? },
            );
        }

        return .{
            .port = 8080,
            .address = "0.0.0.0",
            .payment_processor_default_url = "http://payment-processor-default:8080/payments",
            .payment_processor_fallback_url = "http://payment-processor-fallback:8080/payments",
        };
    }
};
