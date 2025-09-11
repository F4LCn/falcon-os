const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const DoublyLinkedList = @import("../list.zig").DoublyLinkedList;

// []u8 -> the memory we can allocate
// comptime config as input ?
// smallest allocation size as an comptime arg?
// impl the allocator interface
// TODO: add debug info and allocation tracking ?

const log = std.log.scoped(.buddy);

pub const BuddyConfig = struct {
    memory_start: u64,
    memory_length: u64,
    min_size: u64,
    safety: bool = builtin.mode == .Debug or builtin.mode == .ReleaseSafe,
    num_traces: u64 = 6,
};

pub fn NodeStateIdxType(comptime bucket_idx_type: type, comptime node_idx_type: type, comptime max_order: comptime_int) type {
    return struct {
        const node_idx_typeinfo = @typeInfo(node_idx_type);
        value: u64,

        pub fn create(bucket_idx: bucket_idx_type, node_idx: node_idx_type) @This() {
            return .{ .value = (@as(u64, 1) << (max_order - 1 - bucket_idx)) - 1 + @as(u64, node_idx.value) };
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
pub fn NodeIdxType(comptime node_idx_max_log: comptime_int) type {
    const node_idx_type = std.math.IntFittingRange(0, 1 << node_idx_max_log);
    return struct {
        value: node_idx_type,

        pub fn create(node_idx: node_idx_type) @This() {
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
            try writer.print("BucketItem: NodeIdx: {d}", .{self.node_idx.value});
        }
    };
}

pub fn Buddy(comptime config: BuddyConfig) type {
    const min_block_size_log = std.math.log2(config.min_size);
    const max_block_size_log = std.math.log2(config.memory_length);
    const max_order = max_block_size_log - min_block_size_log + 1;
    return struct {
        const BucketIdx = std.math.IntFittingRange(0, max_order - 1);
        const NodeIdx = NodeIdxType(max_block_size_log - min_block_size_log - 1);
        const NodeStateIdx = NodeStateIdxType(BucketIdx, NodeIdx, max_order);
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
            allocated: std.bit_set.ArrayBitSet(u64, (@as(u64, 1) << @as(u6, @intCast(max_order))) - 1) = .initEmpty(),
            stacktraces: [(1 << max_order)][num_trace_types][num_traces]usize = .{.{.{0} ** config.num_traces} ** num_trace_types} ** ((1 << max_order)),
        };

        alloc: Allocator,
        memory_start: u64 = config.memory_start,
        memory_length: u64 = config.memory_length,
        min_block_size_log: u64 = min_block_size_log,
        max_block_size_log: u64 = max_block_size_log,
        max_order: u64 = max_order,
        min_size: u64 = config.min_size,
        buckets: [max_order]BucketFreeList = [1]BucketFreeList{.{}} ** max_order,
        node_state: std.bit_set.ArrayBitSet(u64, (1 << (max_order - 1)) - 1) = .initEmpty(),
        safety_data: if (config.safety) SafetyData else void = if (config.safety) .{} else {},

        pub fn init(alloc: Allocator) !Self {
            var buddy: Self = .{
                .alloc = alloc,
            };
            const first_node = try alloc.create(BucketItem);
            first_node.* = .{ .node_idx = NodeIdx.create(0) };
            buddy.buckets[max_order - 1].append(first_node);
            return buddy;
        }

        pub fn init_test(alloc: Allocator, memory_start: u64) !Self {
            if (builtin.is_test) {
                // const ptr: [*]u8 = @ptrFromInt(memory_start);
                var buddy: Self = .{
                    // .memory = ptr[0..config.memory_length],
                    .memory_start = memory_start,
                    .alloc = alloc,
                };
                const first_node = try alloc.create(BucketItem);
                first_node.* = .{ .node_idx = NodeIdx.create(0) };
                buddy.buckets[max_order - 1].append(first_node);
                return buddy;
            } else {
                @compileError("init_test cannot be used outside of testing");
            }
        }

        pub fn deinit(self: *Self) void {
            if (config.safety) {
                self.checkForLeak();
            }

            for (self.buckets) |bucket| {
                var iter = bucket.iter();
                while (iter.next()) |node| {
                    self.alloc.destroy(node);
                }
            }
        }

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = _alloc,
                    .free = _free,
                    .resize = std.mem.Allocator.noResize,
                    .remap = std.mem.Allocator.noRemap,
                },
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
            const start_ptr = @as(u64, self.memory_start);
            const shift: u6 = @as(u6, @intCast(max_block_size_log + bucket_idx + 1 - max_order));
            const node_length: u64 = @as(u64, 1) << shift;
            const offset = node_length * node_idx.value;
            return start_ptr + offset;
        }

        fn nodeIdxFromPtr(self: *const Self, bucket_idx: BucketIdx, ptr: u64) NodeIdx {
            // std.debug.print("[node2ptr]self.memory is {any}\n", .{self.memory_start});
            const start_ptr = @as(u64, self.memory_start);
            // std.debug.print("start_ptr is 0x{X}\n", .{start_ptr});
            const offset = ptr - start_ptr;
            const shift: u6 = @as(u6, @intCast(max_block_size_log + bucket_idx + 1 - max_order));
            const node_idx = (offset >> shift);
            return .{ .value = @intCast(node_idx) };
        }

        fn buildStackTrace(addresses: *[SafetyData.num_traces]usize, ret_addr: usize) std.builtin.StackTrace {
            // NOTE: this is actually important because we look for 0 to decide how deep we go in the stacktrace
            @memset(addresses, 0);

            var stack_trace: std.builtin.StackTrace = .{
                .instruction_addresses = addresses,
                .index = 0,
            };
            std.debug.captureStackTrace(ret_addr, &stack_trace);
            return stack_trace;
        }

        fn captureStackTrace(self: *Self, bucket_idx: BucketIdx, node_idx: NodeIdx, trace_type: SafetyData.TraceType, ret_addr: usize) void {
            if (!config.safety) @panic("Safety disabled for allocator");
            const total_nodes = (@as(u64, 1) << @as(u6, @intCast(max_order))) - 1;
            const bucket_node_count = @as(u64, 1) << @as(u6, @intCast((max_order - bucket_idx - 1)));
            const node_offset = total_nodes + 1 - bucket_node_count;
            const stack_trace_node_idx = node_offset + node_idx.value;
            const stack_trace_node = &self.safety_data.stacktraces[stack_trace_node_idx];
            const addresses = &stack_trace_node[@intFromEnum(trace_type)];
            _ = buildStackTrace(addresses, ret_addr);
        }

        pub fn allocate(self: *Self, requested_length: u64, alignment: std.mem.Alignment, ret_addr: usize) ![*]u8 {
            const aligned_length = @as(u64, std.mem.alignForwardLog2(requested_length, min_block_size_log));
            const length = alignment.forward(aligned_length);
            const matching_bucket = self.lengthToBucketIdx(length);

            var bucket = matching_bucket;
            if (bucket == max_order - 1) {
                const maybe_node = self.buckets[matching_bucket].popFirst();
                if (maybe_node) |node| {
                    defer self.alloc.destroy(node);
                    const node_idx: NodeIdx = node.node_idx;
                    const ptr = self.ptrFromNodeIdx(matching_bucket, node_idx);
                    try self.recordAllocation(requested_length, length, matching_bucket, node_idx, ret_addr);
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
                        half_node.* = .{ .node_idx = node_idx.child(.right) };
                        self.buckets[bucket - 1].prepend(half_node);
                        node_idx = node_idx.child(.left);
                        bucket -= 1;
                    }
                    const nodestate_idx = NodeStateIdx.create(matching_bucket, node_idx);
                    if (nodestate_idx.parent()) |parent_node_idx| {
                        self.node_state.toggle(parent_node_idx.value);
                    } else |_| {}

                    const ptr = self.ptrFromNodeIdx(matching_bucket, node_idx);
                    try self.recordAllocation(requested_length, length, matching_bucket, node_idx, ret_addr);
                    return @as([*]u8, @ptrFromInt(ptr));
                } else {
                    bucket += 1;
                    continue;
                }
            }
            return error.OutOfMemory;
        }

        pub fn free(self: *Self, ptr: [*]u8, requested_length: u64, alignment: std.mem.Alignment, ret_addr: usize) !void {
            // std.debug.print("[free] self is {*}\n", .{self});
            // std.debug.print("[free] self.memory is {any}\n", .{self.memory_start});
            const aligned_length = @as(u64, std.mem.alignForwardLog2(requested_length, min_block_size_log));
            const length = alignment.forward(aligned_length);
            const matching_bucket = self.lengthToBucketIdx(length);
            const matching_node = self.nodeIdxFromPtr(matching_bucket, @intFromPtr(ptr));
            var node_idx = matching_node;

            var bucket_idx = matching_bucket;
            // std.debug.print("found node at bucket={d} idx={} \n", .{ bucket_idx, node_idx.value });
            while (bucket_idx < max_order) {
                const nodestate_idx = NodeStateIdx.create(bucket_idx, node_idx);
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

            const nodestate_idx = NodeStateIdx.create(bucket_idx, node_idx);
            if (nodestate_idx.parent()) |parent_node_idx| {
                self.node_state.toggle(parent_node_idx.value);
            } else |_| {}
            // std.debug.print("node state fr: {any}\n", .{self.node_state.count()});
            const node = try self.alloc.create(BucketItem);
            errdefer self.alloc.destroy(node);
            node.* = .{ .node_idx = node_idx };
            defer self.buckets[bucket_idx].prepend(node);
            try self.recordFree(requested_length, length, matching_bucket, matching_node, ret_addr);
        }

        pub fn printState(self: *Self) void {
            const max_nodes_bucket = @as(u64, 1) << (max_order - 1);
            var bucket_counter: i64 = max_order - 1;
            while (bucket_counter >= 0) : (bucket_counter -= 1) {
                const bucket_idx = @as(u64, @intCast(bucket_counter));
                const bucket_node_count = @as(u64, 1) << @as(u6, @intCast(max_order - bucket_idx - 1));
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
            if (config.safety) {
                self.safety_data.allocated_size += requested_length;
                self.safety_data.allocated_aligned_size += aligned_length;
                const used_idx = NodeStateIdx.create(bucket_idx, node_idx);
                if (self.safety_data.allocated.isSet(used_idx.value)) {
                    // self.reportDoubleFree(bucket_idx, node_idx, ret_addr);
                    return error.DoubleAlloc;
                }
                self.safety_data.allocated.set(used_idx.value);
                self.captureStackTrace(bucket_idx, node_idx, .allocate, ret_addr);
            }
        }

        fn recordFree(self: *Self, requested_length: u64, aligned_length: u64, bucket_idx: BucketIdx, node_idx: NodeIdx, ret_addr: usize) !void {
            if (config.safety) {
                self.safety_data.allocated_size -= requested_length;
                self.safety_data.allocated_aligned_size -= aligned_length;
                const used_idx = NodeStateIdx.create(bucket_idx, node_idx);
                if (!self.safety_data.allocated.isSet(used_idx.value)) {
                    self.reportDoubleFree(bucket_idx, node_idx, ret_addr);
                    return error.DoubleFree;
                }
                self.safety_data.allocated.unset(used_idx.value);
                self.captureStackTrace(bucket_idx, node_idx, .free, ret_addr);
            }
        }

        fn reportDoubleFree(self: *Self, bucket_idx: BucketIdx, node_idx: NodeIdx, ret_addr: usize) void {
            if (!config.safety) @panic("Safety disabled");
            const addr = self.ptrFromNodeIdx(bucket_idx, node_idx);
            const alloc_stack_trace = self.getCapturedStackTrace(bucket_idx, node_idx, .allocate);
            const free_stack_trace = self.getCapturedStackTrace(bucket_idx, node_idx, .free);
            var addresses: [SafetyData.num_traces]usize = .{0} ** SafetyData.num_traces;
            const stack_trace = buildStackTrace(&addresses, ret_addr);
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
                std.debug.print(report_format, .{ addr, stack_trace, alloc_stack_trace, free_stack_trace });
            } else {
                log.err(report_format, .{ addr, stack_trace, alloc_stack_trace, free_stack_trace });
            }
        }

        fn reportLeak(self: *Self, bucket_idx: BucketIdx, node_idx: NodeIdx) void {
            if (!config.safety) @panic("Safety disabled");
            const addr = self.ptrFromNodeIdx(bucket_idx, node_idx);
            const alloc_stack_trace = self.getCapturedStackTrace(bucket_idx, node_idx, .allocate);
            const report_format =
                \\ ------------------- DOUBLE FREE !!!! ----------------------
                \\ A memory leak was detected at address 0x{X}
                \\ Originally allocated from:
                \\ {f}
                \\
            ;

            if (builtin.is_test) {
                std.debug.print(report_format, .{ addr, alloc_stack_trace });
            } else {
                log.err(report_format, .{ addr, alloc_stack_trace });
            }
        }

        fn getCapturedStackTrace(self: *Self, bucket_idx: BucketIdx, node_idx: NodeIdx, trace_type: SafetyData.TraceType) std.builtin.StackTrace {
            if (!config.safety) @panic("Safety disabled");
            const bucket_node_count = @as(u64, 1) << @as(u6, @intCast(max_order - bucket_idx - 1));
            const total_nodes = (@as(u64, 1) << @as(u6, @intCast(max_order))) - 1;
            const node_offset = total_nodes + 1 - bucket_node_count;
            const stack_trace_node_idx = node_offset + node_idx.value;
            const stack_trace_node = &self.safety_data.stacktraces[stack_trace_node_idx];
            const alloc_addresses = &stack_trace_node[@intFromEnum(trace_type)];
            var len: u64 = 0;
            while (len < SafetyData.num_traces and alloc_addresses[len] != 0) {
                len += 1;
            }
            const stack_trace: std.builtin.StackTrace = .{
                .instruction_addresses = alloc_addresses,
                .index = len,
            };
            return stack_trace;
        }

        fn checkForLeak(self: *Self) void {
            if (!config.safety) @panic("Safety disabled");
            for (0..max_order) |bucket_counter| {
                const bucket_idx: BucketIdx = @intCast(bucket_counter);
                const bucket_node_count = @as(u64, 1) << @as(u6, @intCast(max_order - bucket_idx - 1));
                for (0..bucket_node_count) |node_counter| {
                    const node_idx: NodeIdx = .{ .value = @intCast(node_counter) };
                    const used_idx = NodeStateIdx.create(bucket_idx, node_idx);
                    if (self.safety_data.allocated.isSet(used_idx.value)) {
                        self.reportLeak(bucket_idx, node_idx);
                    }
                }
            }
        }

        fn _alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const res = self.allocate(len, alignment, ret_addr) catch {
                return null;
            };
            return res;
        }

        fn _free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.free(memory.ptr, memory.len, alignment, ret_addr) catch {
                @panic("Unexpected error while freeing memory");
            };
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
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 0 }, (TestBuddy.NodeIdx{ .value = 0 }).child(.left));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 1 }, (TestBuddy.NodeIdx{ .value = 0 }).child(.right));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 2 }, (TestBuddy.NodeIdx{ .value = 1 }).child(.left));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 5 }, (TestBuddy.NodeIdx{ .value = 2 }).child(.right));
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

    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 0 }, buddy.nodeIdxFromPtr(@intCast(7), 0x1000));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 0 }, buddy.nodeIdxFromPtr(@intCast(6), 0x1000));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 1 }, buddy.nodeIdxFromPtr(@intCast(6), 0x1000 + 64));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 0 }, buddy.nodeIdxFromPtr(@intCast(5), 0x1000));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 1 }, buddy.nodeIdxFromPtr(@intCast(5), 0x1000 + 32));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 2 }, buddy.nodeIdxFromPtr(@intCast(5), 0x1000 + 64));
    try std.testing.expectEqual(TestBuddy.NodeIdx{ .value = 3 }, buddy.nodeIdxFromPtr(@intCast(5), 0x1000 + 96));

    try std.testing.expectEqual(0x1000, buddy.ptrFromNodeIdx(@intCast(7), .{ .value = 0 }));
    try std.testing.expectEqual(0x1000, buddy.ptrFromNodeIdx(@intCast(6), .{ .value = 0 }));
    try std.testing.expectEqual(0x1000 + 64, buddy.ptrFromNodeIdx(@intCast(6), .{ .value = 1 }));
    try std.testing.expectEqual(0x1000, buddy.ptrFromNodeIdx(@intCast(5), .{ .value = 0 }));
    try std.testing.expectEqual(0x1000 + 32, buddy.ptrFromNodeIdx(@intCast(5), .{ .value = 1 }));
    try std.testing.expectEqual(0x1000 + 64, buddy.ptrFromNodeIdx(@intCast(5), .{ .value = 2 }));
    try std.testing.expectEqual(0x1000 + 96, buddy.ptrFromNodeIdx(@intCast(5), .{ .value = 3 }));
}

test "Buddy allocate" {
    const test_alloc = std.testing.allocator;

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
        const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1, .safety = false });
        var buddy: TestBuddy = try .init(test_alloc);
        defer buddy.deinit();
        const allocated = try buddy.allocate(128, std.mem.Alignment.@"1", 0);
        try std.testing.expectEqual(0x1000, @intFromPtr(allocated));
        // try std.testing.expectEqual(128, allocated.len);
    }
    {
        // Case 2: allocate 8b from a non split memory then allocate 8b
        const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1, .safety = false });
        var buddy: TestBuddy = try .init(test_alloc);
        defer buddy.deinit();
        const allocated = try buddy.allocate(8, std.mem.Alignment.@"1", 0);
        try std.testing.expectEqual(0x1000, @intFromPtr(allocated));
        const allocated2 = try buddy.allocate(8, std.mem.Alignment.@"1", 0);
        try std.testing.expectEqual(0x1000 + 8, @intFromPtr(allocated2));
    }
    {
        // Case 3: allocate 16b then allocate 8b
        const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1, .safety = false });
        var buddy: TestBuddy = try .init(test_alloc);
        defer buddy.deinit();
        const allocated = try buddy.allocate(16, std.mem.Alignment.@"1", 0);
        try std.testing.expectEqual(0x1000, @intFromPtr(allocated));
        const allocated2 = try buddy.allocate(8, std.mem.Alignment.@"1", 0);
        try std.testing.expectEqual(0x1000 + 16, @intFromPtr(allocated2));
    }
    {
        // Case 4: allocate 8b then allocate 16b then 2b then 1b
        const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1, .safety = false });
        var buddy: TestBuddy = try .init(test_alloc);
        defer buddy.deinit();
        const allocated = try buddy.allocate(8, std.mem.Alignment.@"1", 0);
        try std.testing.expectEqual(0x1000, @intFromPtr(allocated));

        const allocated2 = try buddy.allocate(16, std.mem.Alignment.@"1", 0);
        try std.testing.expectEqual(0x1000 + 16, @intFromPtr(allocated2));

        const allocated3 = try buddy.allocate(2, std.mem.Alignment.@"1", 0);
        try std.testing.expectEqual(0x1000 + 8, @intFromPtr(allocated3));

        const allocated4 = try buddy.allocate(1, std.mem.Alignment.@"1", 0);
        try std.testing.expectEqual(0x1000 + 8 + 2, @intFromPtr(allocated4));
    }
}

test "Buddy free" {
    const test_alloc = std.testing.allocator;

    {
        // Case 1
        const TestBuddy = Buddy(.{ .memory_start = 0x1000, .memory_length = 128, .min_size = 1, .safety = false });
        var buddy: TestBuddy = try .init(test_alloc);
        defer buddy.deinit();
        const alloc8b0 = try buddy.allocate(8, std.mem.Alignment.@"1", 0);
        const alloc16b = try buddy.allocate(16, std.mem.Alignment.@"1", 0);
        const alloc2b0 = try buddy.allocate(2, std.mem.Alignment.@"1", 0);
        const alloc2b1 = try buddy.allocate(2, std.mem.Alignment.@"1", 0);
        const alloc1b = try buddy.allocate(1, std.mem.Alignment.@"1", 0);
        const alloc8b1 = try buddy.allocate(8, std.mem.Alignment.@"1", 0);
        const alloc8b2 = try buddy.allocate(8, std.mem.Alignment.@"1", 0);

        try buddy.free(alloc8b1, 8, std.mem.Alignment.@"1", 0);
        try buddy.free(alloc8b2, 8, std.mem.Alignment.@"1", 0);
        try buddy.free(alloc16b, 16, std.mem.Alignment.@"1", 0);
        try buddy.free(alloc8b0, 8, std.mem.Alignment.@"1", 0);
        try buddy.free(alloc2b1, 2, std.mem.Alignment.@"1", 0);
        try buddy.free(alloc2b0, 2, std.mem.Alignment.@"1", 0);
        try buddy.free(alloc1b, 1, std.mem.Alignment.@"1", 0);
    }
}

test "buddy allocator" {
    const test_alloc = std.testing.allocator;
    const buffer = try test_alloc.alloc(u8, 128);
    defer test_alloc.free(buffer);
    const TestBuddy = Buddy(.{ .memory_start = 0x1, .memory_length = 128, .min_size = @sizeOf(u8) });
    var buddy: TestBuddy = try .init_test(test_alloc, @intFromPtr(buffer.ptr));
    defer buddy.deinit();

    const alloc = buddy.allocator();
    const slice = try alloc.alloc(u64, 10);
    defer alloc.free(slice);
    try std.testing.expectEqual(@intFromPtr(buffer.ptr), @intFromPtr(slice.ptr));
    try std.testing.expectEqual(10, slice.len);
}

test "buddy allocator alignment" {
    const test_alloc = std.testing.allocator;
    const buffer = try test_alloc.alloc(u8, 256);
    defer test_alloc.free(buffer);
    const TestBuddy = Buddy(.{ .memory_start = 0x1, .memory_length = 256, .min_size = @sizeOf(u8) });
    var buddy: TestBuddy = try .init_test(test_alloc, @intFromPtr(buffer.ptr));
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
    std.debug.print("allocated size {d} \n", .{buddy.safety_data.allocated_size});
    std.debug.print("allocated aligned size {d}\n", .{buddy.safety_data.allocated_aligned_size});
}
