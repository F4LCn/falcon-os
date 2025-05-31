const std = @import("std");
const builtin = @import("builtin");
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

pub fn NodeStateIdxType(comptime bucket_idx_type: type, comptime node_idx_type: type, comptime max_order: comptime_int) type {
    return struct {
        const node_idx_typeinfo = @typeInfo(node_idx_type);
        value: u64,

        pub fn create(bucket_idx: bucket_idx_type, node_idx: node_idx_type) @This() {
            return .{ .value = (@as(u64, 1) << (max_order - 1 - bucket_idx)) - 1 + @as(u64, node_idx) };
        }
        // pub fn nodeIdx(self: @This()) node_idx_type {
        //     return @as(node_idx_type, self.value - (1 << (max_order - 1 - bucket_idx)) + 1);
        // }
        pub fn parent(self: @This()) !@This() {
            if (self.value == 0) {
                @branchHint(.cold);
                return error.NoParent;
            }
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

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.print("BucketItem: NodeIdx: {d}", .{self.node_idx});
        }
    };
}

pub fn Buddy(comptime config: BuddyConfig) type {
    const min_block_size_log = std.math.log2(config.min_size);
    const max_block_size_log = std.math.log2(config.memory_length);
    const max_order = max_block_size_log - min_block_size_log + 1;
    return struct {
        const BucketIdx = std.math.IntFittingRange(0, max_order - 1);
        const NodeIdx = std.math.IntFittingRange(0, 1 << (max_block_size_log - min_block_size_log - 1));
        const NodeStateIdx = NodeStateIdxType(BucketIdx, NodeIdx, max_order);
        const BucketItem = BucketItemType(NodeIdx);
        const BucketFreeList = DoublyLinkedList(BucketItem, .prev, .next);

        const Self = @This();
        const memory_ptr: [*]u8 = @ptrFromInt(config.memory_start);

        alloc: Allocator,
        memory: []u8 = memory_ptr[0..config.memory_length],
        min_block_size_log: u64 = min_block_size_log,
        max_block_size_log: u64 = max_block_size_log,
        max_order: u64 = max_order,
        min_size: u64 = config.min_size,
        buckets: [max_order]BucketFreeList = [1]BucketFreeList{.{}} ** max_order,
        node_state: std.bit_set.ArrayBitSet(u64, (1 << (max_order - 1)) - 1) = .initEmpty(),

        pub fn init(alloc: Allocator) !Self {
            var buddy: Self = .{
                .alloc = alloc,
            };
            const first_node = try alloc.create(BucketItem);
            first_node.* = .{ .node_idx = 0 };
            buddy.buckets[max_order - 1].append(first_node);
            return buddy;
        }

        pub fn init_test(alloc: Allocator, memory_start: u64) !Self {
            if (builtin.is_test) {
                const ptr: [*]u8 = @ptrFromInt(memory_start);
                var buddy: Self = .{
                    .memory = ptr[0..config.memory_length],
                    .alloc = alloc,
                };
                const first_node = try alloc.create(BucketItem);
                first_node.* = .{ .node_idx = 0 };
                buddy.buckets[max_order - 1].append(first_node);
                return buddy;
            } else {
                @compileError("init_test cannot be used outside on testing");
            }
        }

        pub fn deinit(self: *Self) void {
            for (self.buckets) |bucket| {
                var iter = bucket.iter();
                while (iter.next()) |node| {
                    self.alloc.destroy(node);
                }
            }
        }

        pub fn allocator(self: *@This()) Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = _alloc,
                    .resize = std.mem.Allocator.noResize,
                    .remap = std.mem.Allocator.noRemap,
                    .free = std.mem.Allocator.noFree,
                },
            };
        }

        fn nodeChild(self: NodeIdx, side: enum { left, right }) NodeIdx {
            return switch (side) {
                .left => (self << 1),
                .right => (self << 1) + 1,
            };
        }

        fn lengthToBucketIdx(self: *const Self, len: u64) BucketIdx {
            var order: u64 = 0;
            var size = self.min_size;

            while (size < len) {
                size *= 2;
                order += 1;
            }

            return @intCast(order);
        }

        fn ptrFromNodeIdx(self: *const Self, bucket_idx: BucketIdx, node_idx: NodeIdx) u64 {
            const start_ptr = @as(u64, @intFromPtr(self.memory.ptr));
            const shift: u6 = @as(u6, @intCast(max_block_size_log + bucket_idx + 1 - max_order));
            const node_length: u64 = @as(u64, 1) << shift;
            const offset = node_length * node_idx;
            return start_ptr + offset;
        }

        fn nodeIdxFromPtr(self: *const Self, bucket_idx: BucketIdx, ptr: u64) NodeIdx {
            const start_ptr = @as(u64, @intFromPtr(self.memory.ptr));
            const offset = ptr - start_ptr;
            const shift: u6 = @as(u6, @intCast(max_block_size_log + bucket_idx - max_order + 1));
            const node_idx = (offset >> shift);
            return @intCast(node_idx);
        }

        pub fn allocate(self: *Self, requested_length: u64) ![*]u8 {
            const length = @as(u64, std.mem.alignForwardLog2(requested_length, min_block_size_log));
            const matching_bucket = self.lengthToBucketIdx(length);

            var bucket = matching_bucket;

            if (bucket == max_order - 1) {
                const maybe_node = self.buckets[matching_bucket].popFirst();
                if (maybe_node) |node| {
                    defer self.alloc.destroy(node);
                    const node_idx: NodeIdx = node.node_idx;
                    const ptr = self.ptrFromNodeIdx(matching_bucket, node_idx);
                    return @as([*]u8, @ptrFromInt(ptr));
                }
                return error.OutOfMemory;
            }

            while (bucket < max_order) {
                const maybe_node = self.buckets[bucket].popFirst();
                if (maybe_node) |node| {
                    defer self.alloc.destroy(node);
                    var node_idx: NodeIdx = node.node_idx;
                    while (bucket > matching_bucket) {
                        const nodestate_idx = NodeStateIdx.create(bucket, node_idx);
                        if (nodestate_idx.parent()) |parent_node_idx| {
                            self.node_state.toggle(parent_node_idx.value);
                        } else |_| {}
                        const half_node = try self.alloc.create(BucketItem);
                        half_node.* = .{ .node_idx = nodeChild(node_idx, .right) };
                        self.buckets[bucket - 1].prepend(half_node);
                        node_idx = nodeChild(node_idx, .left);
                        bucket -= 1;
                    }
                    const nodestate_idx = NodeStateIdx.create(matching_bucket, node_idx);
                    if (nodestate_idx.parent()) |parent_node_idx| {
                        self.node_state.toggle(parent_node_idx.value);
                    } else |_| {}

                    const ptr = self.ptrFromNodeIdx(matching_bucket, node_idx);
                    return @as([*]u8, @ptrFromInt(ptr));
                } else {
                    bucket += 1;
                    continue;
                }
            }
            return error.OutOfMemory;
        }

        fn _alloc(context: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.allocate(len) catch {
                return null;
            };
        }
    };
}

test "Buddy" {
    const TestBuddy = Buddy(.{ .memory_start = 0x1234, .memory_length = 128, .min_size = 1 });
    const NodeIdx = TestBuddy.NodeIdx;
    const value_type = @typeInfo(NodeIdx);
    const BucketIdx = TestBuddy.BucketIdx;
    const bucket_type = @typeInfo(BucketIdx);

    try std.testing.expectEqual(7, value_type.int.bits);
    try std.testing.expectEqual(3, bucket_type.int.bits);
}

test "nodestate idx sibling" {
    const TestBuddy = Buddy(.{ .memory_start = 0x1234, .memory_length = 128, .min_size = 1 });
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 2 }, (TestBuddy.NodeStateIdx{ .value = 1 }).sibling());
}

test "nodestate idx parent" {
    const TestBuddy = Buddy(.{ .memory_start = 0x1234, .memory_length = 128, .min_size = 1 });
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 0 }, (TestBuddy.NodeStateIdx{ .value = 1 }).parent());
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 0 }, (TestBuddy.NodeStateIdx{ .value = 2 }).parent());
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 1 }, (TestBuddy.NodeStateIdx{ .value = 3 }).parent());
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 2 }, (TestBuddy.NodeStateIdx{ .value = 6 }).parent());
}

test "nodestate idx children" {
    const TestBuddy = Buddy(.{ .memory_start = 0x1234, .memory_length = 128, .min_size = 1 });
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 1 }, (TestBuddy.NodeStateIdx{ .value = 0 }).child(.left));
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 2 }, (TestBuddy.NodeStateIdx{ .value = 0 }).child(.right));
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 3 }, (TestBuddy.NodeStateIdx{ .value = 1 }).child(.left));
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 6 }, (TestBuddy.NodeStateIdx{ .value = 2 }).child(.right));
}

test "node idx children" {
    const TestBuddy = Buddy(.{ .memory_start = 0x1234, .memory_length = 128, .min_size = 1 });
    try std.testing.expectEqual(0, TestBuddy.nodeChild(0, .left));
    try std.testing.expectEqual(1, TestBuddy.nodeChild(0, .right));
    try std.testing.expectEqual(2, TestBuddy.nodeChild(1, .left));
    try std.testing.expectEqual(5, TestBuddy.nodeChild(2, .right));
}

test "buddy init test" {
    const test_alloc = std.testing.allocator;
    const TestBuddy = Buddy(.{ .memory_start = 0x1234, .memory_length = 128, .min_size = 1 });
    var buddy: TestBuddy = try .init(test_alloc);
    defer buddy.deinit();

    try std.testing.expectEqual(0, buddy.min_block_size_log);
    try std.testing.expectEqual(7, buddy.max_block_size_log);
    try std.testing.expectEqual(8, buddy.max_order);
    try std.testing.expectEqual(127, buddy.node_state.capacity());
    try std.testing.expectEqual(buddy.max_order, buddy.buckets.len);
}

test "buddy test" {
    const test_alloc = std.testing.allocator;
    const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1 });
    var buddy: TestBuddy = try .init(test_alloc);
    defer buddy.deinit();

    const bucketIdx = buddy.lengthToBucketIdx(64);
    try std.testing.expectEqual(6, bucketIdx);

    try std.testing.expectEqual(0, buddy.nodeIdxFromPtr(@intCast(7), 0x1000));
    try std.testing.expectEqual(0, buddy.nodeIdxFromPtr(@intCast(6), 0x1000));
    try std.testing.expectEqual(1, buddy.nodeIdxFromPtr(@intCast(6), 0x1000 + 64));
    try std.testing.expectEqual(0, buddy.nodeIdxFromPtr(@intCast(5), 0x1000));
    try std.testing.expectEqual(1, buddy.nodeIdxFromPtr(@intCast(5), 0x1000 + 32));
    try std.testing.expectEqual(2, buddy.nodeIdxFromPtr(@intCast(5), 0x1000 + 64));
    try std.testing.expectEqual(3, buddy.nodeIdxFromPtr(@intCast(5), 0x1000 + 96));

    try std.testing.expectEqual(0x1000, buddy.ptrFromNodeIdx(@intCast(7), 0));
    try std.testing.expectEqual(0x1000, buddy.ptrFromNodeIdx(@intCast(6), 0));
    try std.testing.expectEqual(0x1000 + 64, buddy.ptrFromNodeIdx(@intCast(6), 1));
    try std.testing.expectEqual(0x1000, buddy.ptrFromNodeIdx(@intCast(5), 0));
    try std.testing.expectEqual(0x1000 + 32, buddy.ptrFromNodeIdx(@intCast(5), 1));
    try std.testing.expectEqual(0x1000 + 64, buddy.ptrFromNodeIdx(@intCast(5), 2));
    try std.testing.expectEqual(0x1000 + 96, buddy.ptrFromNodeIdx(@intCast(5), 3));
}

test "Buddy allocate" {
    const test_alloc = std.testing.allocator;

    {
        // Case 1: allocate the full memory
        const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1 });
        var buddy: TestBuddy = try .init(test_alloc);
        defer buddy.deinit();
        const allocated = try buddy.allocate(128);
        try std.testing.expectEqual(0x1000, @intFromPtr(allocated));
        // try std.testing.expectEqual(128, allocated.len);
    }

    {
        // Case 2: allocate 8b from a non split memory then allocate 8b
        const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1 });
        var buddy: TestBuddy = try .init(test_alloc);
        defer buddy.deinit();
        const allocated = try buddy.allocate(8);
        try std.testing.expectEqual(0x1000, @intFromPtr(allocated));
        // try std.testing.expectEqual(8, allocated.len);
        for (buddy.buckets, 0..) |b, i| {
            std.debug.print("[bucket{d}] {any}\n", .{ i, b });
        }
        const allocated2 = try buddy.allocate(8);
        try std.testing.expectEqual(0x1000 + 8, @intFromPtr(allocated2));
        // try std.testing.expectEqual(8, allocated2.len);
        for (buddy.buckets, 0..) |b, i| {
            std.debug.print("[bucket{d}] {any}\n", .{ i, b });
        }
    }

    {
        // Case 3: allocate 16b then allocate 8b
        const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1 });
        var buddy: TestBuddy = try .init(test_alloc);
        defer buddy.deinit();
        const allocated = try buddy.allocate(16);
        try std.testing.expectEqual(0x1000, @intFromPtr(allocated));
        // try std.testing.expectEqual(16, allocated.len);
        for (buddy.buckets, 0..) |b, i| {
            std.debug.print("[bucket{d}] {any}\n", .{ i, b });
        }
        const allocated2 = try buddy.allocate(8);
        try std.testing.expectEqual(0x1000 + 16, @intFromPtr(allocated2));
        // try std.testing.expectEqual(8, allocated2.len);
        for (buddy.buckets, 0..) |b, i| {
            std.debug.print("[bucket{d}] {any}\n", .{ i, b });
        }
    }

    {
        // Case 4: allocate 8b then allocate 16b
        const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1 });
        var buddy: TestBuddy = try .init(test_alloc);
        defer buddy.deinit();
        const allocated = try buddy.allocate(8);
        try std.testing.expectEqual(0x1000, @intFromPtr(allocated));
        // try std.testing.expectEqual(8, allocated.len);
        for (buddy.buckets, 0..) |b, i| {
            std.debug.print("[bucket{d}] {any}\n", .{ i, b });
        }
        const allocated2 = try buddy.allocate(16);
        try std.testing.expectEqual(0x1000 + 16, @intFromPtr(allocated2));
        // try std.testing.expectEqual(16, allocated2.len);
        for (buddy.buckets, 0..) |b, i| {
            std.debug.print("[bucket{d}] {any}\n", .{ i, b });
        }
        const allocated3 = try buddy.allocate(2);
        try std.testing.expectEqual(0x1000 + 8, @intFromPtr(allocated3));
        // try std.testing.expectEqual(2, allocated3.len);
        for (buddy.buckets, 0..) |b, i| {
            std.debug.print("[bucket{d}] {any}\n", .{ i, b });
        }
        const allocated4 = try buddy.allocate(1);
        try std.testing.expectEqual(0x1000 + 8 + 2, @intFromPtr(allocated4));
        // try std.testing.expectEqual(1, allocated4.len);
        for (buddy.buckets, 0..) |b, i| {
            std.debug.print("[bucket{d}] {any}\n", .{ i, b });
        }
    }
}

test "buddy allocator" {
    const test_alloc = std.testing.allocator;
    const buffer = try test_alloc.alloc(u8, 128);
    defer test_alloc.free(buffer);
    std.debug.print("buffer: 0x{X} with size {d}", .{ @intFromPtr(&buffer), buffer.len });
    const TestBuddy = Buddy(.{ .memory_start = 0x1, .memory_length = 128, .min_size = @sizeOf(u8) });
    var buddy: TestBuddy = try .init_test(test_alloc, @intFromPtr(&buffer));
    defer buddy.deinit();

    const alloc = buddy.allocator();
    const slice = try alloc.alloc(u64, 10);
    try std.testing.expectEqual(@intFromPtr(&buffer), @intFromPtr(slice.ptr));
    try std.testing.expectEqual(10, slice.len);
}
