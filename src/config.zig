const std = @import("std");
const dotenv = @import("dotenv");

const ConfigKeys = enum { PAYMENT_PROCESSOR_DEFAULT, PAYMENT_PROCESSOR_FALLBACK, ADDRESS, PORT };

pub const Config = struct {
    port: u16,
    address: []const u8,
    payment_processor_default_url: []const u8,
    payment_processor_fallback_url: []const u8,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        var envs = try dotenv.getDataFrom(allocator, ".env");
        defer envs.deinit();

        var config: @This() = undefined;

        const enum_info = @typeInfo(ConfigKeys).@"enum";
        inline for (enum_info.fields) |field| {
            const enum_tag_name = field.name;

            if (envs.contains(enum_tag_name)) {
                const value = envs.get(enum_tag_name).?;
                const key_enum = @field(ConfigKeys, enum_tag_name);

                switch (key_enum) {
                    .PAYMENT_PROCESSOR_DEFAULT => config.payment_processor_default_url = value.?,
                    .PAYMENT_PROCESSOR_FALLBACK => config.payment_processor_fallback_url = value.?,
                    .ADDRESS => config.address = value.?,
                    .PORT => {
                        config.port = try std.fmt.parseInt(u16, value.?, 10);
                    },
                }
            }
        }

        return config;
    }
};
