const std = @import("std");
const Allocator = std.mem.Allocator;
const DoublyLinkedList = @import("../list.zig").DoublyLinkedList;

// []u8 -> the memory we can allocate
// comptime config as input ?
// smallest allocation size as an comptime arg?
// impl the allocator interface
// TODO: add debug info and allocation tracking ?

pub const BuddyConfig = struct {
    memory_start: u64,
    memory_length: u64,
    min_size: u64,
};

pub fn NodeIdxType(comptime size: comptime_int) type {
    return struct {
        value: std.math.IntFittingRange(0, size),
        pub fn parent(self: @This()) @This() {
            return .{ .value = (self.value - 1) >> 1 };
        }
        pub fn child(self: @This(), side: enum { left, right }) @This() {
            return .{ .value = switch (side) {
                .left => (self.value << 1) + 1,
                .right => (self.value << 1) + 2,
            } };
        }
        pub fn sibling(self: @This()) @This() {
            return .{ .value = (self.value - 1) ^ 1 + 1 };
        }
    };
}

pub fn BucketItemType(comptime node_idx_type: type) type {
    return struct {
        prev: ?*@This() = null,
        next: ?*@This() = null,
        node_idx: node_idx_type,
    };
}

pub fn Buddy(comptime config: BuddyConfig) type {
    const min_block_size_log = std.math.log2(config.min_size);
    const max_block_size_log = std.math.log2(config.memory_length);
    const max_order = max_block_size_log - min_block_size_log + 1;
    return struct {
        const NodeIdx = NodeIdxType(1 << (max_block_size_log - min_block_size_log - 1));
        const BucketItem = BucketItemType(NodeIdx);
        const BucketFreeList = DoublyLinkedList(BucketItem, .prev, .next);

        const Self = @This();
        const BucketIdx = std.math.IntFittingRange(0, max_order - 1);
        const memory_ptr: [*]u8 = @ptrFromInt(config.memory_start);

        alloc: Allocator,
        memory: []u8 = memory_ptr[0..config.memory_length],
        min_block_size_log: u64 = min_block_size_log,
        max_block_size_log: u64 = max_block_size_log,
        max_order: u64 = max_order,
        min_size: u64 = config.min_size,
        buckets: [max_order]BucketFreeList = [1]BucketFreeList{.{}} ** max_order,
        node_state: std.bit_set.ArrayBitSet(u64, 1 << (max_order - 1) - 1) = .initEmpty(),

        pub fn init(alloc: Allocator) !Self {
            var buddy: Self = .{
                .alloc = alloc,
            };
            const first_node = try alloc.create(BucketItem);
            first_node.* = .{ .node_idx = .{ .value = 0 } };
            buddy.buckets[max_order - 1].append(first_node);
            return buddy;
        }

        pub fn deinit(self: *Self) void {
            for (self.buckets) |bucket| {
                var iter = bucket.iter();
                while (iter.next()) |node| {
                    self.alloc.destroy(node);
                }
            }
        }

        fn lengthToBucketIdx(self: *const Self, len: u64) BucketIdx {
            var order = max_order - 1;
            var size = self.min_size;

            while (size < len) {
                size *= 2;
                order -= 1;
            }

            return @intCast(order);
        }

        fn ptrFromNodeIdx(self: *const Self, bucket_idx: BucketIdx, node_idx: NodeIdx) u64 {
            const start_ptr = @as(u64, @intFromPtr(self.memory.ptr));
            const shift: u6 = @as(u6, @intCast(max_block_size_log + bucket_idx - max_order + 1));
            const node_length: u64 = @as(u64, 1) << shift;
            const offset = node_length * node_idx.value;
            return start_ptr + offset;
        }

        fn nodeIdxFromPtr(self: *const Self, bucket_idx: BucketIdx, ptr: u64) NodeIdx {
            const start_ptr = @as(u64, @intFromPtr(self.memory.ptr));
            const offset = ptr - start_ptr;
            const shift: u6 = @as(u6, @intCast(max_block_size_log + bucket_idx - max_order + 1));
            const node_idx = (offset >> shift);
            return .{ .value = @intCast(node_idx) };
        }

        pub fn allocate(self: *Self, requested_length: u64) []u8 {
            const length = @as(u64, std.mem.alignForwardLog2(requested_length, min_block_size_log));
            const matching_bucket = self.lengthToBucketIdx(length);

            var bucket = matching_bucket;

            while (bucket < max_order) {
                const maybe_node = self.buckets[matching_bucket].popFirst();
                if (maybe_node) |node| {
                    defer self.alloc.destroy(node);
                    const node_idx: NodeIdx = node.node_idx;
                    while (bucket > matching_bucket) {
                        self.node_state.toggle(node_idx.parent());
                        const half_node = self.alloc.create(BucketItem);
                        half_node.* = .{ .node_idx = node_idx.child(.right) };
                        self.buckets[bucket - 1].prepend(half_node);
                        node_idx = node_idx.child(.left);
                        bucket -= 1;
                    }
                    self.node_state.toggle(node_idx.parent());
                    const ptr = ptrFromNodeIdx(matching_bucket, node_idx);
                    const slice = @as([*]u8, @ptrFromInt(ptr));
                    return slice[0..requested_length];
                } else {
                    bucket += 1;
                    continue;
                }
            }
        }
    };
}

test "Buddy" {
    const TestBuddy = Buddy(.{ .memory_start = 0x1234, .memory_length = 128, .min_size = 1 });
    const NodeIdx = TestBuddy.NodeIdx;
    const value_type = @typeInfo(@FieldType(NodeIdx, "value"));
    const BucketIdx = TestBuddy.BucketIdx;
    const bucket_type = @typeInfo(BucketIdx);

    try std.testing.expectEqual(7, value_type.int.bits);
    try std.testing.expectEqual(3, bucket_type.int.bits);
}

test "node idx sibling" {
    const TestBuddy = Buddy(.{ .memory_start = 0x1234, .memory_length = 128, .min_size = 1 });
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 2 }, (TestBuddy.NodeIdx{ .value = 1 }).sibling());
}

test "node idx parent" {
    const TestBuddy = Buddy(.{ .memory_start = 0x1234, .memory_length = 128, .min_size = 1 });
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 0 }, (TestBuddy.NodeIdx{ .value = 1 }).parent());
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 0 }, (TestBuddy.NodeIdx{ .value = 2 }).parent());
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 1 }, (TestBuddy.NodeIdx{ .value = 3 }).parent());
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 2 }, (TestBuddy.NodeIdx{ .value = 6 }).parent());
}

test "node idx children" {
    const TestBuddy = Buddy(.{ .memory_start = 0x1234, .memory_length = 128, .min_size = 1 });
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 1 }, (TestBuddy.NodeIdx{ .value = 0 }).child(.left));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 2 }, (TestBuddy.NodeIdx{ .value = 0 }).child(.right));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 3 }, (TestBuddy.NodeIdx{ .value = 1 }).child(.left));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 6 }, (TestBuddy.NodeIdx{ .value = 2 }).child(.right));
}

test "buddy init test" {
    const test_alloc = std.testing.allocator;
    const TestBuddy = Buddy(.{ .memory_start = 0x1234, .memory_length = 128, .min_size = 1 });
    var buddy: TestBuddy = try .init(test_alloc);
    defer buddy.deinit();

    try std.testing.expectEqual(0, buddy.min_block_size_log);
    try std.testing.expectEqual(7, buddy.max_block_size_log);
    try std.testing.expectEqual(8, buddy.max_order);
    try std.testing.expectEqual(64, buddy.node_state.capacity());
    try std.testing.expectEqual(buddy.max_order, buddy.buckets.len);
}

test "buddy test" {
    const test_alloc = std.testing.allocator;
    const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1 });
    var buddy: TestBuddy = try .init(test_alloc);
    defer buddy.deinit();

    const bucketIdx = buddy.lengthToBucketIdx(64);
    try std.testing.expectEqual(1, bucketIdx);

    try std.testing.expectEqual(0, buddy.nodeIdxFromPtr(@intCast(7), 0x1000).value);
    try std.testing.expectEqual(0, buddy.nodeIdxFromPtr(@intCast(6), 0x1000).value);
    try std.testing.expectEqual(1, buddy.nodeIdxFromPtr(@intCast(6), 0x1000 + 64).value);
    try std.testing.expectEqual(0, buddy.nodeIdxFromPtr(@intCast(5), 0x1000).value);
    try std.testing.expectEqual(1, buddy.nodeIdxFromPtr(@intCast(5), 0x1000 + 32).value);
    try std.testing.expectEqual(2, buddy.nodeIdxFromPtr(@intCast(5), 0x1000 + 64).value);
    try std.testing.expectEqual(3, buddy.nodeIdxFromPtr(@intCast(5), 0x1000 + 96).value);

    try std.testing.expectEqual(0x1000, buddy.ptrFromNodeIdx(@intCast(7), .{.value = 0}));
    try std.testing.expectEqual(0x1000, buddy.ptrFromNodeIdx(@intCast(6), .{.value = 0}));
    try std.testing.expectEqual(0x1000 + 64, buddy.ptrFromNodeIdx(@intCast(6), .{.value = 1}));
    try std.testing.expectEqual(0x1000, buddy.ptrFromNodeIdx(@intCast(5), .{.value = 0}));
    try std.testing.expectEqual(0x1000 + 32, buddy.ptrFromNodeIdx(@intCast(5), .{.value = 1}));
    try std.testing.expectEqual(0x1000 + 64, buddy.ptrFromNodeIdx(@intCast(5), .{.value = 2}));
    try std.testing.expectEqual(0x1000 + 96, buddy.ptrFromNodeIdx(@intCast(5), .{.value = 3}));
}
