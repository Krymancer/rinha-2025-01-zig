const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub const StorageEntry = struct {
    amount: u32,
    requested_at: i64,
};

pub const BitPackingPaymentStorage = struct {
    const Self = @This();

    start_timestamp: i64,
    data: ArrayList(u32),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) Self {
        return Self{
            .start_timestamp = std.time.milliTimestamp(),
            .data = ArrayList(u32).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit();
    }

    pub fn reset(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.data.clearRetainingCapacity();
        self.start_timestamp = std.time.milliTimestamp();
    }

    pub fn push(self: *Self, amount: u32, current_timestamp: i64) !void {
        std.log.info("Pushing payment: amount={}, timestamp={}", .{ amount, current_timestamp });
        const delta = current_timestamp - self.start_timestamp;

        if (delta < 0 or delta > 86_400_000) {
            return error.TimestampOutOfRange;
        }

        if (amount > 4_095) {
            return error.AmountOutOfRange;
        }

        // Pack: 20 bits for delta (up to ~1M ms), 12 bits for amount (up to 4095)
        const packed_value: u32 = (@as(u32, @intCast(delta)) << 12) | amount;
        std.log.info("Packed value: {x}", .{packed_value});

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.data.append(packed_value);
    }

    pub fn list(self: *Self, allocator: Allocator) ![]StorageEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        var entries = try allocator.alloc(StorageEntry, self.data.items.len);

        for (self.data.items, 0..) |entry, i| {
            const delta = entry >> 12;
            const amount = entry & 0xFFF;
            entries[i] = StorageEntry{
                .amount = amount,
                .requested_at = self.start_timestamp + @as(i64, delta),
            };
        }

        std.log.info("Listed {} entries", .{entries.len});
        for (entries) |e| {
            std.log.info("Entry: amount={}, requested_at={}", .{ e.amount, e.requested_at });
        }

        return entries;
    }
};

pub const State = struct {
    const Self = @This();

    default: BitPackingPaymentStorage,
    fallback: BitPackingPaymentStorage,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Self {
        return Self{
            .default = BitPackingPaymentStorage.init(allocator),
            .fallback = BitPackingPaymentStorage.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.default.deinit();
        self.fallback.deinit();
    }
};
