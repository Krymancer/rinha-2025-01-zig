fn handlePurgePayments(self: *Self, connection: net.Server.Connection) !void {
    self.state.default.reset();
    self.state.fallback.reset();
    try self.sendResponse(connection, "200 OK", "");
}
