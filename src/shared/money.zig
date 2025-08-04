const std = @import("std");

pub fn floatToCents(value: f64) u32 {
    return @intFromFloat(@round(value * 100.0));
}

pub fn centsToFloat(value: u32) f64 {
    return @as(f64, @floatFromInt(value)) / 100.0;
}
