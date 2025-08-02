const std = @import("std");
const queue_service = @import("services/queue_service.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Test compilation", .{});
    _ = allocator;
    _ = queue_service;
}
