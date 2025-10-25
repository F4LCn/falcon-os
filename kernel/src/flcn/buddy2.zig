const std = @import("std");
const debug = @import("debug.zig");
const builtin = @import("builtin");
const mem_allocator = @import("allocator.zig");
const options = @import("options");
const pmm = @import("pmm.zig");

const DoublyLinkedList = @import("list.zig").DoublyLinkedList;

const log = std.log.scoped(.buddy);

pub const BuddyConfig = struct {
    min_size: u64,
    safety: bool = builtin.mode == .Debug or builtin.mode == .ReleaseSafe,
    num_traces: u64 = options.num_stack_trace,
};

pub fn NodeStateIdxType(comptime bucket_idx_type: type, comptime node_idx_type: type) type {
    return struct {
        const node_idx_typeinfo = @typeInfo(node_idx_type);
        value: u64,

        pub fn create(bucket_idx: bucket_idx_type, node_idx: node_idx_type, max_order: u6) @This() {
            return .{ .value = (@as(u64, 1) << @as(u6, @intCast(max_order - 1 - bucket_idx))) - 1 + @as(u64, node_idx.value) };
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
const NodeIdxType = struct {
    value: u64,

    pub fn create(node_idx: u64) @This() {
        return .{ .value = node_idx };
    }

    pub fn parent(self: @This()) !@This() {
        return .{ .value = self.value >> 1 };
    }

    pub fn child(self: @This(), side: enum { left, right }) @This() {
        return .{ .value = switch (side) {
            .left => (self.value << 1),
            .right => (self.value << 1) + 1,
        } };
    }

    pub fn sibling(self: @This()) @This() {
        return .{ .value = self.value ^ 1 };
    }
};

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
            try writer.print("BucketItem: NodeIdx: {d}", .{self.node_idx.value});
        }
    };
}

pub fn BuddyAllocator(comptime config: BuddyConfig) type {
    const min_block_size_log = std.math.log2(config.min_size);
    return struct {
        const BucketIdx = u64;
        const NodeIdx = NodeIdxType;
        const NodeStateIdx = NodeStateIdxType(BucketIdx, NodeIdx);
        const BucketItem = BucketItemType(NodeIdx);
        const BucketFreeList = DoublyLinkedList(BucketItem, .prev, .next);

        const Self = @This();

        const SafetyData = struct {
            pub const TraceType = enum { allocate, free };
            const num_trace_types = std.enums.directEnumArrayLen(TraceType, 0);
            const num_traces = config.num_traces;
            // TODO: move allocation tracking to the buddy itself
            // as it can be used to determine if we can allocate a size/alignment before doing the work
            allocated_size: u64 = 0,
            allocated_aligned_size: u64 = 0,
            allocated: std.bit_set.DynamicBitSetUnmanaged,
            stacktraces: [][num_trace_types]debug.Stacktrace,

            pub fn init(alloc: std.mem.Allocator, num_nodes: u64) !@This() {
                const safety_data: @This() = .{
                    .allocated = try .initEmpty(alloc, num_nodes),
                    .stacktraces = try alloc.alloc([num_trace_types]debug.Stacktrace, num_nodes + 1),
                };
                for (safety_data.stacktraces) |*stacktrace| {
                    stacktrace.* = .{debug.Stacktrace{}} ** num_trace_types;
                }
                return safety_data;
            }

            pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
                self.allocated.deinit(alloc);
                alloc.free(self.stacktraces);
            }
        };

        alloc: std.mem.Allocator,
        memory_start: u64,
        memory_length: u64,
        min_block_size_log: u64 = min_block_size_log,
        max_block_size_log: u64,
        min_size: u64 = config.min_size,
        buckets: []BucketFreeList,
        node_state: std.bit_set.DynamicBitSetUnmanaged,
        max_order: u6,
        safety_data: if (config.safety) SafetyData else void,

        pub fn initFromSlice(alloc: std.mem.Allocator, memory: []u8) !Self {
            return try .init(alloc, @intFromPtr(memory.ptr), memory.len);
        }

        pub fn init(alloc: std.mem.Allocator, start: u64, length: u64) !Self {
            if (!std.mem.Alignment.fromByteUnits(4096).check(start)) {
                @panic("Expected page aligned memory");
            }
            const max_block_size_log: u64 = @intCast(std.math.log2(length));
            const max_order: u6 = @intCast(max_block_size_log - min_block_size_log + 1);
            const num_nodes = (@as(u64, 1) << max_order) - 1;
            const node_state_count = (@as(u64, 1) << (max_order - 1)) - 1;
            var buddy: Self = .{
                .alloc = alloc,
                .max_block_size_log = max_block_size_log,
                .max_order = max_order,
                .buckets = try alloc.alloc(BucketFreeList, max_order),
                .node_state = try .initEmpty(alloc, node_state_count),
                .memory_start = start,
                .memory_length = length,
                .safety_data = if (config.safety) try .init(alloc, num_nodes) else {},
            };
            for (buddy.buckets) |*bucket| {
                bucket.* = .{};
            }
            const first_node = try alloc.create(BucketItem);
            first_node.* = .{ .node_idx = NodeIdx.create(0) };
            buddy.buckets[max_order - 1].append(first_node);
            return buddy;
        }

        pub fn deinit(self: *Self) void {
            if (config.safety) {
                self.checkForLeak();
                self.safety_data.deinit(self.alloc);
            }

            for (self.buckets) |*bucket| {
                var iter = bucket.iter();
                while (iter.next()) |node| {
                    self.alloc.destroy(node);
                }
            }
            self.alloc.free(self.buckets);
            self.node_state.deinit(self.alloc);
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
            const start_ptr = @as(u64, self.memory_start);
            const shift: u6 = @as(u6, @intCast(self.max_block_size_log + bucket_idx + 1 - self.max_order));
            const node_length: u64 = @as(u64, 1) << shift;
            const offset = node_length * node_idx.value;
            return start_ptr + offset;
        }

        fn nodeIdxFromPtr(self: *const Self, bucket_idx: BucketIdx, ptr: u64) NodeIdx {
            // std.debug.print("[node2ptr]self.memory is {any}\n", .{self.memory_start});
            const start_ptr = @as(u64, self.memory_start);
            // std.debug.print("start_ptr is 0x{X}\n", .{start_ptr});
            const offset = ptr - start_ptr;
            const shift: u6 = @as(u6, @intCast(self.max_block_size_log + bucket_idx + 1 - self.max_order));
            const node_idx = (offset >> shift);
            return .{ .value = @intCast(node_idx) };
        }

        fn captureStackTrace(self: *Self, bucket_idx: BucketIdx, node_idx: NodeIdx, trace_type: SafetyData.TraceType, ret_addr: usize) void {
            if (!config.safety) @panic("Safety disabled for allocator");
            const total_nodes = (@as(u64, 1) << @as(u6, @intCast(self.max_order))) - 1;
            const bucket_node_count = @as(u64, 1) << @as(u6, @intCast((self.max_order - bucket_idx - 1)));
            const node_offset = total_nodes + 1 - bucket_node_count;
            const stack_trace_node_idx = node_offset + node_idx.value;
            const stack_trace_node = &self.safety_data.stacktraces[stack_trace_node_idx];
            const stacktrace = &stack_trace_node[@intFromEnum(trace_type)];
            _ = stacktrace.capture(ret_addr);
        }

        pub fn canAlloc(self: *Self, requested_length: usize, alignment: std.mem.Alignment) bool {
            const aligned_length = @as(u64, std.mem.alignForwardLog2(requested_length, min_block_size_log));
            const length = alignment.forward(aligned_length);
            if (length > self.memory_length) return false;
            const matching_bucket = self.lengthToBucketIdx(length);
            var bucket = matching_bucket;
            while (bucket < self.max_order) {
                var iter = self.buckets[bucket].iter();
                if (iter.next()) |_| {
                    return true;
                } else {
                    bucket += 1;
                }
            }
            return false;
        }

        pub fn allocate(self: *Self, requested_length: u64, alignment: std.mem.Alignment, ret_addr: usize) !pmm.PhysMemRange {
            const aligned_length = @as(u64, std.mem.alignForwardLog2(requested_length, min_block_size_log));
            const length = alignment.forward(aligned_length);
            const matching_bucket = self.lengthToBucketIdx(length);

            var bucket = matching_bucket;
            if (bucket == self.max_order - 1) {
                const maybe_node = self.buckets[matching_bucket].popFirst();
                if (maybe_node) |node| {
                    defer self.alloc.destroy(node);
                    const node_idx: NodeIdx = node.node_idx;
                    const ptr = self.ptrFromNodeIdx(matching_bucket, node_idx);
                    try self.recordAllocation(requested_length, length, matching_bucket, node_idx, ret_addr);
                    return .{ .start = ptr, .length = length, .typ = .free };
                }
                return error.OutOfMemory;
            }

            while (bucket < self.max_order) {
                const maybe_node = self.buckets[bucket].popFirst();
                if (maybe_node) |node| {
                    defer self.alloc.destroy(node);
                    var node_idx: NodeIdx = node.node_idx;
                    while (bucket > matching_bucket) {
                        const nodestate_idx = NodeStateIdx.create(bucket, node_idx, self.max_order);
                        if (nodestate_idx.parent()) |parent_node_idx| {
                            self.node_state.toggle(parent_node_idx.value);
                        } else |_| {}
                        const half_node = try self.alloc.create(BucketItem);
                        half_node.* = .{ .node_idx = node_idx.child(.right) };
                        self.buckets[bucket - 1].prepend(half_node);
                        node_idx = node_idx.child(.left);
                        bucket -= 1;
                    }
                    const nodestate_idx = NodeStateIdx.create(matching_bucket, node_idx, self.max_order);
                    if (nodestate_idx.parent()) |parent_node_idx| {
                        self.node_state.toggle(parent_node_idx.value);
                    } else |_| {}

                    const ptr = self.ptrFromNodeIdx(matching_bucket, node_idx);
                    try self.recordAllocation(requested_length, length, matching_bucket, node_idx, ret_addr);
                    return .{ .start = ptr, .length = length, .typ = .free };
                } else {
                    bucket += 1;
                    continue;
                }
            }
            return error.OutOfMemory;
        }

        pub fn free(self: *Self, range: pmm.PhysMemRange, ret_addr: usize) !void {
            // std.debug.print("[free] self is {*}\n", .{self});
            // std.debug.print("[free] self.memory is {any}\n", .{self.memory_start});
            const ptr = range.start;
            const length = range.length;
            const matching_bucket = self.lengthToBucketIdx(length);
            const matching_node = self.nodeIdxFromPtr(matching_bucket, ptr);
            var node_idx = matching_node;

            var bucket_idx = matching_bucket;
            // std.debug.print("found node at bucket={d} idx={} \n", .{ bucket_idx, node_idx.value });
            while (bucket_idx < self.max_order) {
                const nodestate_idx = NodeStateIdx.create(bucket_idx, node_idx, self.max_order);
                if (nodestate_idx.parent()) |parent_node_idx| {
                    // std.debug.print("parent state {any} \n", .{self.node_state.isSet(parent_node_idx.value)});
                    if (!self.node_state.isSet(parent_node_idx.value)) {
                        break;
                    }

                    const buddy_node_idx = node_idx.sibling();
                    // std.debug.print("buddy node is bucket={d} idx={d} \n", .{ bucket_idx, buddy_node_idx.value });
                    var iter = self.buckets[bucket_idx].iter();
                    while (iter.next()) |node| {
                        if (node.node_idx.value == buddy_node_idx.value) {
                            defer self.alloc.destroy(node);
                            defer self.buckets[bucket_idx].remove(node);
                            break;
                        }
                    }

                    // std.debug.print("recombining idx={d} and idx={d} to bucket={} \n", .{ node_idx.value, buddy_node_idx.value, bucket_idx + 1 });
                    self.node_state.toggle(parent_node_idx.value);

                    // const ni = node_idx;
                    node_idx = node_idx.parent() catch {
                        // std.debug.print("No parent sadge {d} \n", .{ni.value});
                        break;
                    };
                    bucket_idx += 1;
                } else |_| {
                    break;
                }
            }

            const nodestate_idx = NodeStateIdx.create(bucket_idx, node_idx, self.max_order);
            if (nodestate_idx.parent()) |parent_node_idx| {
                self.node_state.toggle(parent_node_idx.value);
            } else |_| {}
            // std.debug.print("node state fr: {any}\n", .{self.node_state.count()});
            const node = try self.alloc.create(BucketItem);
            errdefer self.alloc.destroy(node);
            node.* = .{ .node_idx = node_idx };
            defer self.buckets[bucket_idx].prepend(node);
            try self.recordFree(length, length, matching_bucket, matching_node, ret_addr);
        }

        pub fn printState(self: *Self) void {
            const max_nodes_bucket = @as(u64, 1) << (self.max_order - 1);
            var bucket_counter: i64 = self.max_order - 1;
            while (bucket_counter >= 0) : (bucket_counter -= 1) {
                const bucket_idx = @as(u64, @intCast(bucket_counter));
                const bucket_node_count = @as(u64, 1) << @as(u6, @intCast(self.max_order - bucket_idx - 1));
                const num_chars_per_item = @divExact(max_nodes_bucket, bucket_node_count); // + (@as(u64, 1) << @as(u6, @intCast(bucket_idx)));
                var buffer: [512]u8 = .{' '} ** 512;
                var iter = self.buckets[bucket_idx].iter();
                var set = std.bit_set.ArrayBitSet(usize, max_nodes_bucket).initEmpty();
                while (iter.next()) |node| {
                    const node_idx = node.node_idx.value;
                    set.set(node_idx);
                }

                for (0..bucket_node_count) |i| {
                    buffer[i * num_chars_per_item + num_chars_per_item - 1] = '|';
                }
                for (0..bucket_node_count) |i| {
                    if (set.isSet(i)) {
                        const pos = i * num_chars_per_item;
                        buffer[pos] = '*';
                    }
                }
                for (0..bucket_node_count) |i| {
                    const nodestate_idx = NodeStateIdx.create(@intCast(bucket_idx), .{ .value = @intCast(i) });
                    if (nodestate_idx.value < self.node_state.capacity() and self.node_state.isSet(nodestate_idx.value)) {
                        const pos = i * num_chars_per_item;
                        buffer[pos] = '#';
                    }
                }
                std.debug.print("[{d:0>2}] {s}\n", .{ bucket_idx, buffer[0..max_nodes_bucket] });

                buffer = .{'_'} ** 512;
                std.debug.print("[{d:0>2}] {s}\n", .{ bucket_idx, buffer[0..max_nodes_bucket] });
            }
        }

        fn recordAllocation(self: *Self, requested_length: u64, aligned_length: u64, bucket_idx: BucketIdx, node_idx: NodeIdx, ret_addr: usize) !void {
            if (!config.safety) return;
            self.safety_data.allocated_size += requested_length;
            self.safety_data.allocated_aligned_size += aligned_length;
            const used_idx = NodeStateIdx.create(bucket_idx, node_idx, self.max_order);
            if (self.safety_data.allocated.isSet(used_idx.value)) {
                return error.DoubleAlloc;
            }
            self.safety_data.allocated.set(used_idx.value);
            self.captureStackTrace(bucket_idx, node_idx, .allocate, ret_addr);
        }

        fn recordFree(self: *Self, requested_length: u64, aligned_length: u64, bucket_idx: BucketIdx, node_idx: NodeIdx, ret_addr: usize) !void {
            if (!config.safety) return;
            self.safety_data.allocated_size -= requested_length;
            self.safety_data.allocated_aligned_size -= aligned_length;
            const used_idx = NodeStateIdx.create(bucket_idx, node_idx, self.max_order);
            if (!self.safety_data.allocated.isSet(used_idx.value)) {
                self.reportDoubleFree(bucket_idx, node_idx, ret_addr);
                return error.DoubleFree;
            }
            self.safety_data.allocated.unset(used_idx.value);
            self.captureStackTrace(bucket_idx, node_idx, .free, ret_addr);
        }

        fn reportDoubleFree(self: *Self, bucket_idx: BucketIdx, node_idx: NodeIdx, ret_addr: usize) void {
            @branchHint(.cold);
            if (!config.safety) @panic("Safety disabled");
            const addr = self.ptrFromNodeIdx(bucket_idx, node_idx);
            const alloc_stack_trace = self.getCapturedStackTrace(bucket_idx, node_idx, .allocate);
            const free_stack_trace = self.getCapturedStackTrace(bucket_idx, node_idx, .free);
            var stacktrace: debug.Stacktrace = .{};
            stacktrace.capture(ret_addr);
            const report_format =
                \\ ------------------- DOUBLE FREE !!!! ----------------------
                \\ A double free was detected at address 0x{X}
                \\ {f}
                \\
                \\ Originally allocated from:
                \\ {f}
                \\
                \\ Originally freed from:
                \\ {f}
                \\
            ;

            if (builtin.is_test) {
                std.debug.print(report_format, .{ addr, stacktrace, alloc_stack_trace, free_stack_trace });
            } else {
                log.err(report_format, .{ addr, stacktrace, alloc_stack_trace, free_stack_trace });
            }
        }

        fn reportLeak(self: *Self, bucket_idx: BucketIdx, node_idx: NodeIdx) void {
            @branchHint(.cold);
            if (!config.safety) @panic("Safety disabled");
            const addr = self.ptrFromNodeIdx(bucket_idx, node_idx);
            const alloc_stacktrace = self.getCapturedStackTrace(bucket_idx, node_idx, .allocate);
            const report_format =
                \\ ------------------- MEMORY LEAK !!!! ----------------------
                \\ A memory leak was detected at address 0x{X}
                \\ Originally allocated from:
                \\ {f}
                \\
            ;

            if (builtin.is_test) {
                std.debug.print(report_format, .{ addr, alloc_stacktrace });
            } else {
                log.err(report_format, .{ addr, alloc_stacktrace });
            }
        }

        fn getCapturedStackTrace(self: *Self, bucket_idx: BucketIdx, node_idx: NodeIdx, trace_type: SafetyData.TraceType) *const debug.Stacktrace {
            if (!config.safety) @panic("Safety disabled");
            const bucket_node_count = @as(u64, 1) << @as(u6, @intCast(self.max_order - bucket_idx - 1));
            const total_nodes = (@as(u64, 1) << @as(u6, @intCast(self.max_order))) - 1;
            const node_offset = total_nodes + 1 - bucket_node_count;
            const stacktrace_node_idx = node_offset + node_idx.value;
            const stacktraces = &self.safety_data.stacktraces[stacktrace_node_idx];
            const stacktrace = &stacktraces[@intFromEnum(trace_type)];
            return stacktrace;
        }

        fn checkForLeak(self: *Self) void {
            if (!config.safety) @panic("Safety disabled");
            for (0..self.max_order) |bucket_counter| {
                const bucket_idx: BucketIdx = @intCast(bucket_counter);
                const bucket_node_count = @as(u64, 1) << @as(u6, @intCast(self.max_order - bucket_idx - 1));
                for (0..bucket_node_count) |node_counter| {
                    const node_idx: NodeIdx = .{ .value = @intCast(node_counter) };
                    const used_idx = NodeStateIdx.create(bucket_idx, node_idx, self.max_order);
                    if (self.safety_data.allocated.isSet(used_idx.value)) {
                        self.reportLeak(bucket_idx, node_idx);
                    }
                }
            }
        }
    };
}

test "nodestate idx sibling" {
    const TestBuddy = BuddyAllocator(.{});
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 2 }, (TestBuddy.NodeStateIdx{ .value = 1 }).sibling());
}

test "nodestate idx parent" {
    const TestBuddy = BuddyAllocator(.{});
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 0 }, (TestBuddy.NodeStateIdx{ .value = 1 }).parent());
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 0 }, (TestBuddy.NodeStateIdx{ .value = 2 }).parent());
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 1 }, (TestBuddy.NodeStateIdx{ .value = 3 }).parent());
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 2 }, (TestBuddy.NodeStateIdx{ .value = 6 }).parent());
}

test "nodestate idx children" {
    const TestBuddy = BuddyAllocator(.{});
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 1 }, (TestBuddy.NodeStateIdx{ .value = 0 }).child(.left));
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 2 }, (TestBuddy.NodeStateIdx{ .value = 0 }).child(.right));
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 3 }, (TestBuddy.NodeStateIdx{ .value = 1 }).child(.left));
    try std.testing.expectEqual(TestBuddy.NodeStateIdx{ .value = 6 }, (TestBuddy.NodeStateIdx{ .value = 2 }).child(.right));
}

test "node idx children" {
    const TestBuddy = BuddyAllocator(.{});
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 0 }, (TestBuddy.NodeIdx{ .value = 0 }).child(.left));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 1 }, (TestBuddy.NodeIdx{ .value = 0 }).child(.right));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 2 }, (TestBuddy.NodeIdx{ .value = 1 }).child(.left));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 5 }, (TestBuddy.NodeIdx{ .value = 2 }).child(.right));
}

test "buddy init test" {
    const test_alloc = std.testing.allocator;
    const buffer = try test_alloc.alignedAlloc(u8, .fromByteUnits(4096), 128);
    defer test_alloc.free(buffer);
    const TestBuddy = BuddyAllocator(.{});
    var buddy: TestBuddy = try .init(test_alloc, buffer);
    defer buddy.deinit();

    try std.testing.expectEqual(0, buddy.min_block_size_log);
    try std.testing.expectEqual(7, buddy.max_block_size_log);
    try std.testing.expectEqual(8, buddy.max_order);
    try std.testing.expectEqual(127, buddy.node_state.capacity());
    try std.testing.expectEqual(buddy.max_order, buddy.buckets.len);
}

test "buddy test" {
    const test_alloc = std.testing.allocator;
    const buffer = try test_alloc.alignedAlloc(u8, .fromByteUnits(4096), 128);
    defer test_alloc.free(buffer);
    const TestBuddy = BuddyAllocator(.{});
    var buddy: TestBuddy = try .init(test_alloc, buffer);
    defer buddy.deinit();
    const buffer_start = @intFromPtr(buffer.ptr);

    const bucketIdx = buddy.lengthToBucketIdx(64);
    try std.testing.expectEqual(6, bucketIdx);

    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 0 }, buddy.nodeIdxFromPtr(@intCast(7), buffer_start));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 0 }, buddy.nodeIdxFromPtr(@intCast(6), buffer_start));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 1 }, buddy.nodeIdxFromPtr(@intCast(6), buffer_start + 64));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 0 }, buddy.nodeIdxFromPtr(@intCast(5), buffer_start));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 1 }, buddy.nodeIdxFromPtr(@intCast(5), buffer_start + 32));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 2 }, buddy.nodeIdxFromPtr(@intCast(5), buffer_start + 64));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 3 }, buddy.nodeIdxFromPtr(@intCast(5), buffer_start + 96));

    try std.testing.expectEqual(buffer_start, buddy.ptrFromNodeIdx(@intCast(7), .{ .value = 0 }));
    try std.testing.expectEqual(buffer_start, buddy.ptrFromNodeIdx(@intCast(6), .{ .value = 0 }));
    try std.testing.expectEqual(buffer_start + 64, buddy.ptrFromNodeIdx(@intCast(6), .{ .value = 1 }));
    try std.testing.expectEqual(buffer_start, buddy.ptrFromNodeIdx(@intCast(5), .{ .value = 0 }));
    try std.testing.expectEqual(buffer_start + 32, buddy.ptrFromNodeIdx(@intCast(5), .{ .value = 1 }));
    try std.testing.expectEqual(buffer_start + 64, buddy.ptrFromNodeIdx(@intCast(5), .{ .value = 2 }));
    try std.testing.expectEqual(buffer_start + 96, buddy.ptrFromNodeIdx(@intCast(5), .{ .value = 3 }));
}

test "Buddy allocate" {
    const test_alloc = std.testing.allocator;
    const buffer = try test_alloc.alignedAlloc(u8, .fromByteUnits(4096), 128);
    defer test_alloc.free(buffer);
    const buffer_start = @intFromPtr(buffer.ptr);

    // {
    //     const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1 });
    //     var buddy: TestBuddy = try .init(test_alloc);
    //     defer buddy.deinit();
    //     const allocated = try buddy.allocate(1, std.mem.Alignment.@"1", 0);
    //     try std.testing.expectEqual(0x1000, @intFromPtr(allocated));
    //     const allocated2 = try buddy.allocate(1, std.mem.Alignment.@"1", 0);
    //     _ = allocated2;
    // }
    {
        // Case 1: allocate the full memory
        const TestBuddy = BuddyAllocator(.{ .safety = false });
        var buddy: TestBuddy = try .init(test_alloc, buffer);
        defer buddy.deinit();
        const allocated = try buddy.allocate(128, .@"1", 0);
        defer buddy.free(allocated, 128, .@"1", 0) catch unreachable;
        try std.testing.expectEqual(buffer_start, @intFromPtr(allocated));
        // try std.testing.expectEqual(128, allocated.len);
    }
    {
        // Case 2: allocate 8b from a non split memory then allocate 8b
        const TestBuddy = BuddyAllocator(.{ .safety = false });
        var buddy: TestBuddy = try .init(test_alloc, buffer);
        defer buddy.deinit();
        const allocated = try buddy.allocate(8, .@"1", 0);
        defer buddy.free(allocated, 8, .@"1", 0) catch unreachable;
        try std.testing.expectEqual(buffer_start, @intFromPtr(allocated));
        const allocated2 = try buddy.allocate(8, .@"1", 0);
        defer buddy.free(allocated2, 8, .@"1", 0) catch unreachable;
        try std.testing.expectEqual(buffer_start + 8, @intFromPtr(allocated2));
    }
    {
        // Case 3: allocate 16b then allocate 8b
        const TestBuddy = BuddyAllocator(.{ .safety = false });
        var buddy: TestBuddy = try .init(test_alloc, buffer);
        defer buddy.deinit();
        const allocated = try buddy.allocate(16, .@"1", 0);
        defer buddy.free(allocated, 16, .@"1", 0) catch unreachable;
        try std.testing.expectEqual(buffer_start, @intFromPtr(allocated));
        const allocated2 = try buddy.allocate(8, .@"1", 0);
        defer buddy.free(allocated2, 8, .@"1", 0) catch unreachable;
        try std.testing.expectEqual(buffer_start + 16, @intFromPtr(allocated2));
    }
    {
        // Case 4: allocate 8b then allocate 16b then 2b then 1b
        const TestBuddy = BuddyAllocator(.{ .safety = false });
        var buddy: TestBuddy = try .init(test_alloc, buffer);
        defer buddy.deinit();
        const allocated = try buddy.allocate(8, .@"1", 0);
        defer buddy.free(allocated, 8, .@"1", 0) catch unreachable;
        try std.testing.expectEqual(buffer_start, @intFromPtr(allocated));
        const allocated2 = try buddy.allocate(16, .@"1", 0);
        defer buddy.free(allocated2, 16, .@"1", 0) catch unreachable;
        try std.testing.expectEqual(buffer_start + 16, @intFromPtr(allocated2));
        const allocated3 = try buddy.allocate(2, .@"1", 0);
        defer buddy.free(allocated3, 2, .@"1", 0) catch unreachable;
        try std.testing.expectEqual(buffer_start + 8, @intFromPtr(allocated3));
        const allocated4 = try buddy.allocate(1, .@"1", 0);
        defer buddy.free(allocated4, 1, .@"1", 0) catch unreachable;
        try std.testing.expectEqual(buffer_start + 8 + 2, @intFromPtr(allocated4));
    }
}

test "Buddy free" {
    const test_alloc = std.testing.allocator;
    const buffer = try test_alloc.alignedAlloc(u8, .fromByteUnits(4096), 128);
    defer test_alloc.free(buffer);

    {
        // Case 1
        const TestBuddy = BuddyAllocator(.{ .safety = false });
        var buddy: TestBuddy = try .init(test_alloc, buffer);
        defer buddy.deinit();
        const alloc8b0 = try buddy.allocate(8, .@"1", 0);
        const alloc16b = try buddy.allocate(16, .@"1", 0);
        const alloc2b0 = try buddy.allocate(2, .@"1", 0);
        const alloc2b1 = try buddy.allocate(2, .@"1", 0);
        const alloc1b = try buddy.allocate(1, .@"1", 0);
        const alloc8b1 = try buddy.allocate(8, .@"1", 0);
        const alloc8b2 = try buddy.allocate(8, .@"1", 0);

        try buddy.free(alloc8b1, 8, .@"1", 0);
        try buddy.free(alloc8b2, 8, .@"1", 0);
        try buddy.free(alloc16b, 16, .@"1", 0);
        try buddy.free(alloc8b0, 8, .@"1", 0);
        try buddy.free(alloc2b1, 2, .@"1", 0);
        try buddy.free(alloc2b0, 2, .@"1", 0);
        try buddy.free(alloc1b, 1, .@"1", 0);
    }
}

test "buddy allocator" {
    const test_alloc = std.testing.allocator;
    const buffer = try test_alloc.alignedAlloc(u8, .fromByteUnits(4096), 128);
    defer test_alloc.free(buffer);
    const TestBuddy = BuddyAllocator(.{});
    var buddy: TestBuddy = try .init(test_alloc, buffer);
    defer buddy.deinit();

    const alloc = buddy.allocator();
    const slice = try alloc.alloc(u64, 10);
    defer alloc.free(slice);
    try std.testing.expectEqual(@intFromPtr(buffer.ptr), @intFromPtr(slice.ptr));
    try std.testing.expectEqual(10, slice.len);
}

test "buddy allocator alignment" {
    const test_alloc = std.testing.allocator;
    const buffer = try test_alloc.alignedAlloc(u8, .fromByteUnits(4096), 256);
    defer test_alloc.free(buffer);
    const TestBuddy = BuddyAllocator(.{ .min_size = @sizeOf(u8) });
    var buddy: TestBuddy = try .init(test_alloc, buffer);
    defer buddy.deinit();

    var validationAlloc = std.mem.validationWrap(&buddy);
    blk: {
        const alloc = validationAlloc.allocator();
        const check = try alloc.alloc(u8, 128);
        defer alloc.free(check);
        const slice = try alloc.alloc(u64, 3);
        defer alloc.free(slice);
        try std.testing.expectEqual(3, slice.len);
        const slice2_alignment = std.mem.Alignment.fromByteUnits(64);
        const slice2 = try alloc.alignedAlloc(u64, .fromByteUnits(64), 1);
        try std.testing.expectEqual(1, slice2.len);
        try std.testing.expect(slice2_alignment.check(@intFromPtr(slice2.ptr)));
        defer alloc.free(slice2);
        // This is impossible to allocate given the alignment constraint
        // we assert that we do get the OutOfMemory error
        const slice3 = alloc.alignedAlloc(u64, std.mem.Alignment.fromByteUnits(128), 1) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            break :blk;
        };
        defer alloc.free(slice3);
    }
    // std.debug.print("allocated size {d} \n", .{buddy.safety_data.allocated_size});
    // std.debug.print("allocated aligned size {d}\n", .{buddy.safety_data.allocated_aligned_size});
}

test "can allocate" {
    const test_alloc = std.testing.allocator;
    const buffer = try test_alloc.alloc(u8, 256);
    defer test_alloc.free(buffer);
    const TestBuddy = BuddyAllocator(.{ .min_size = @sizeOf(u8) });
    var buddy: TestBuddy = try .init(test_alloc, buffer);
    defer buddy.deinit();

    const alloc = buddy.allocator();
    try std.testing.expectEqual(true, buddy.canAlloc(@sizeOf(u8) * 128, .of(u8)));
    const check = try alloc.alloc(u8, 128);
    defer alloc.free(check);
    try std.testing.expectEqual(true, buddy.canAlloc(@sizeOf(u64) * 3, .of(u64)));
    const slice = try alloc.alloc(u64, 3);
    defer alloc.free(slice);
    try std.testing.expectEqual(3, slice.len);
    const slice2_alignment = std.mem.Alignment.fromByteUnits(64);
    try std.testing.expectEqual(true, buddy.canAlloc(@sizeOf(u64), .fromByteUnits(64)));
    const slice2 = try alloc.alignedAlloc(u64, .fromByteUnits(64), 1);
    try std.testing.expectEqual(1, slice2.len);
    try std.testing.expect(slice2_alignment.check(@intFromPtr(slice2.ptr)));
    defer alloc.free(slice2);
    try std.testing.expectEqual(false, buddy.canAlloc(@sizeOf(u64), .fromByteUnits(128)));
}
