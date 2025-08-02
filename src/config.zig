const std = @import("std");

pub const ProcessorType = enum {
    default,
    fallback,
};

pub const payment_processor_urls = struct {
    pub const default = "http://payment-processor-default:8080";
    pub const fallback = "http://payment-processor-fallback:8080";
};

pub const Config = struct {
    socket_path: []const u8,
    foreign_state: []const u8,
    is_fire_mode: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Config {
        const socket_path = std.process.getEnvVarOwned(allocator, "SOCKET_PATH") catch try allocator.dupe(u8, "/tmp/app.sock");

        const foreign_state = std.process.getEnvVarOwned(allocator, "FOREIGN_STATE") catch try allocator.dupe(u8, "");

        const mode = std.process.getEnvVarOwned(allocator, "MODE") catch null;

        const is_fire_mode = if (mode) |m|
            std.mem.eql(u8, m, "🔥")
        else
            false;

        if (mode) |m| allocator.free(m);

        return Config{
            .socket_path = socket_path,
            .foreign_state = foreign_state,
            .is_fire_mode = is_fire_mode,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.socket_path);
        self.allocator.free(self.foreign_state);
    }
};
