const std = @import("std");

pub fn sendResponse(allocator: std.mem.Allocator, connection: std.net.Server.Connection, status: []const u8, body: []const u8) !void {
    const response = try std.fmt.allocPrint(allocator, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, body.len, body });
    defer allocator.free(response);

    _ = try connection.stream.writeAll(response);
}

pub fn sendJsonResponse(allocator: std.mem.Allocator, connection: std.net.Server.Connection, json_body: []const u8) !void {
    try sendResponse(allocator, connection, "200 OK", json_body);
}
