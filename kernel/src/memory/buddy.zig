const std = @import("std");
const Allocator = std.mem.Allocator;
const DoublyLinkedList = @import("../list.zig").DoublyLinkedList;

// []u8 -> the memory we can allocate
// comptime config as input ?
// smallest allocation size as an comptime arg?
// impl the allocator interface
// TODO: add debug info and allocation tracking ?

pub const BuddyConfig = struct {
    memory: []u8,
    min_size: u64,
};

pub fn Buddy(comptime config: BuddyConfig) type {
    const min_block_size_log = std.math.log2(config.min_size);
    const max_block_size_log = std.math.log2(config.memory.len);
    const NodeIdx = struct {
        value: std.math.IntFittingRange(0, 1 << (max_block_size_log - min_block_size_log)),
        pub fn parent(self: @This()) @This() {
            return .{ .value = (self.value - 1) >> 1 };
        }
        pub fn child(self: @This(), side: enum { left, right }) @This() {
            return .{ .value = switch (side) {
                .left => self.value << 1,
                .right => self.value << 1 + 1,
            } };
        }
        pub fn sibling(self: @This()) @This() {
            return .{ .value = self.value ^ 1 };
        }
    };
    const BucketItem = struct {
        prev: ?*@This() = null,
        next: ?*@This() = null,
        node_idx: NodeIdx,
    };
    const BucketFreeList = DoublyLinkedList(BucketItem, .prev, .next);
    return struct {
        const Self = @This();
        const max_order = max_block_size_log - min_block_size_log;

        const BucketIdx = std.math.IntFittingRange(0, max_order - 1);
        alloc: Allocator,
        memory: []u8 = config.memory,
        min_block_size_log: u64 = min_block_size_log,
        max_block_size_log: u64 = max_block_size_log,
        min_size: u64 = config.min_size,
        buckets: [max_order]BucketFreeList = [1]BucketFreeList{} ** max_order,
        node_state: std.bit_set.ArrayBitSet(1 << (max_order - 1) - 1) = .initEmpty(),

        pub fn init(alloc: Allocator) !Self {
            var buddy: Self = .{ .alloc = alloc };
            const first_node = try alloc.create(BucketItem);
            first_node.* = .{ .node_idx = 0 };
            buddy.buckets[max_order - 1].append(first_node);
        }

        fn lengthToBucketIdx(self: *const Self, len: u64) BucketIdx {
            var order = max_order - 1;
            var size = self.min_size;

            while (size < len) {
                size *= 2;
                order -= 1;
            }

            return order;
        }

        fn ptrFromNodeIdx(self: *const Self, bucket_idx: BucketIdx, node_idx: NodeIdx) u64 {
            const start_ptr = @as(u64, @intFromPtr(self.memory.ptr));
            const node_length = 1 << (max_block_size_log - max_order - 1 + @as(u64, bucket_idx));
            const offset = node_length * node_idx;
            return (start_ptr + offset);
        }

        // TODO: write tests
        fn nodeIdxFromPtr(self: *const Self, bucket_idx: BucketIdx, ptr: u64) NodeIdx {
            const offset = ptr - @as(u64, @intFromPtr(self.memory.ptr));
            const node_idx = offset >> (max_block_size_log - @as(u64, bucket_idx));
            return @as(NodeIdx, node_idx);
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
