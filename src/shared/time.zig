const std = @import("std");

pub fn parseTimestamp(date_str: []const u8) ?i64 {
    const timestamp = std.fmt.parseInt(i64, date_str, 10) catch return null;
    return timestamp;
}
