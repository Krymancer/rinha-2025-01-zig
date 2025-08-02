const std = @import("std");

pub fn main() !void {
    std.debug.print("Testing atomic...\n", .{});
    var counter = std.atomic.Value(u32).init(0);
    _ = counter.fetchAdd(1, .seq_cst);
    std.debug.print("Counter: {}\n", .{counter.load(.seq_cst)});
}
