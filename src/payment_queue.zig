const std = @import("std");

pub fn PaymentQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            data: T,
            next: ?*Node,
        };

        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,
        head: ?*Node,
        tail: ?*Node,
        allocator: std.mem.Allocator,
        size: std.atomic.Value(u32),
        is_closed: std.atomic.Value(bool),

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .mutex = std.Thread.Mutex{},
                .condition = std.Thread.Condition{},
                .head = null,
                .tail = null,
                .allocator = allocator,
                .size = std.atomic.Value(u32).init(0),
                .is_closed = std.atomic.Value(bool).init(false),
            };
        }

        pub fn deinit(self: *Self) void {
            self.close();
            // Clean up remaining items
            while (self.pop()) |_| {}
        }

        pub fn push(self: *Self, item: T) !void {
            if (self.is_closed.load(.acquire)) {
                return error.QueueClosed;
            }

            const node = try self.allocator.create(Node);
            node.* = Node{
                .data = item,
                .next = null,
            };

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.tail) |tail| {
                tail.next = node;
                self.tail = node;
            } else {
                self.head = node;
                self.tail = node;
            }

            _ = self.size.fetchAdd(1, .acq_rel);
            self.condition.signal();
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head) |head| {
                const data = head.data;
                self.head = head.next;
                if (self.head == null) {
                    self.tail = null;
                }
                self.allocator.destroy(head);
                _ = self.size.fetchSub(1, .acq_rel);
                return data;
            }
            return null;
        }

        pub fn waitAndPop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.head == null and !self.is_closed.load(.acquire)) {
                self.condition.wait(&self.mutex);
            }

            if (self.head) |head| {
                const data = head.data;
                self.head = head.next;
                if (self.head == null) {
                    self.tail = null;
                }
                self.allocator.destroy(head);
                _ = self.size.fetchSub(1, .acq_rel);
                return data;
            }
            return null;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.size.load(.acquire) == 0;
        }

        pub fn getSize(self: *Self) u32 {
            return self.size.load(.acquire);
        }

        pub fn close(self: *Self) void {
            self.is_closed.store(true, .release);
            self.condition.broadcast();
        }
    };
}
