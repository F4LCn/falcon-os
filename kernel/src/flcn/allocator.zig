const std = @import("std");
const DoublyLinkedList = @import("list.zig").DoublyLinkedList;

pub const SubHeapAllocator = struct {
    ptr: *anyopaque,
    can_alloc: *const fn (*anyopaque, usize, std.mem.Alignment) bool,
    can_free: *const fn (*anyopaque, []u8, std.mem.Alignment) bool,
    allocated_memory: *const fn (*anyopaque) u64,
    memory_stats: *const fn (*anyopaque, []u8) anyerror!void,
    create_allocator: *const fn (*anyopaque) std.mem.Allocator,

    pub fn canAlloc(self: *SubHeapAllocator, len: usize, alignment: std.mem.Alignment) bool {
        return self.can_alloc(self.ptr, len, alignment);
    }

    pub fn canFree(self: *SubHeapAllocator, memory: []u8, alignment: std.mem.Alignment) bool {
        return self.can_free(self.ptr, memory, alignment);
    }

    pub fn allocatedMemory(self: *SubHeapAllocator) u64 {
        return self.allocated_memory(self.ptr);
    }

    pub fn memoryStats(self: *SubHeapAllocator, buffer: []u8) !void {
        try self.memory_stats(self.ptr, buffer);
    }

    pub fn allocator(self: *SubHeapAllocator) std.mem.Allocator {
        return self.create_allocator(self.ptr);
    }
};

pub fn PageAllocator(comptime alignment: std.mem.Alignment) type {
    return struct {
        pub const AllocateArgs = struct { zero: bool = true };
        pub const FreeArgs = struct { poison: bool = true };
        const page_alignment = alignment.toByteUnits();
        const Self = @This();
        ptr: *anyopaque,
        vtable: *const VTable,
        pub const VTable = struct {
            allocate: *const fn (*anyopaque, count: u64, args: AllocateArgs) anyerror![*]align(page_alignment) u8,
            free: *const fn (*anyopaque, ptr: [*]align(page_alignment) u8, count: u64, args: FreeArgs) anyerror!void,
        };

        pub fn allocate(self: Self, count: u64, args: AllocateArgs) ![*]align(page_alignment) u8 {
            return try self.vtable.allocate(self.ptr, count, .{ .zero = args.zero });
        }
        pub fn free(self: Self, ptr: [*]align(page_alignment) u8, count: u64, args: FreeArgs) !void {
            return try self.vtable.free(self.ptr, ptr, count, .{ .poison = args.poison });
        }
    };
}

pub fn AllocatorAdapter(comptime T: type) type {
    const CanAllocFn = *const fn (*T, usize, std.mem.Alignment) bool;
    const CanFreeFn = *const fn (*T, []u8, std.mem.Alignment) bool;
    const AllocatedMemoryFn = *const fn (*T) u64;
    const MemoryStatsFn = *const fn (*T, []u8) anyerror!void;
    if (!@hasDecl(T, "allocator")) {
        @compileError("Type " ++ T ++ " is not an allocator");
    }
    return struct {
        alloc: *T,
        can_alloc: CanAllocFn,
        can_free: CanFreeFn,
        allocated_memory: AllocatedMemoryFn,
        memory_stats: MemoryStatsFn,

        pub fn init(alloc: *T, args: struct {
            can_alloc: ?CanAllocFn = null,
            can_free: ?CanFreeFn = null,
            allocated_memory: ?AllocatedMemoryFn = null,
            memory_stats: ?MemoryStatsFn = null,
        }) @This() {
            const can_alloc_fn = if (@hasDecl(T, "canAlloc")) blk: {
                break :blk T.canAlloc;
            } else args.can_alloc.?;

            const can_free_fn = if (@hasDecl(T, "canfree")) blk: {
                break :blk T.canfree;
            } else args.can_free.?;

            const allocated_memory_fn = if (@hasDecl(T, "allocatedMemory")) blk: {
                break :blk T.canfree;
            } else args.allocated_memory.?;

            const memory_stats_fn = if (@hasDecl(T, "memoryStats")) blk: {
                break :blk T.canfree;
            } else args.memory_stats.?;

            return .{
                .alloc = alloc,
                .can_alloc = can_alloc_fn,
                .can_free = can_free_fn,
                .allocated_memory = allocated_memory_fn,
                .memory_stats = memory_stats_fn,
            };
        }

        fn canAlloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.can_alloc(self.alloc, len, alignment);
        }
        fn canFree(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.can_free(self.alloc, memory, alignment);
        }
        fn allocatedMemory(ptr: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.allocated_memory(self.alloc);
        }
        fn memoryStats(ptr: *anyopaque, buffer: []u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.memory_stats(self.alloc, buffer);
        }
        fn createAllocator(ptr: *anyopaque) std.mem.Allocator {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.alloc.allocator();
        }

        pub fn subHeapAllocator(self: *@This()) SubHeapAllocator {
            return .{
                .ptr = self,
                .can_alloc = canAlloc,
                .can_free = canFree,
                .allocated_memory = allocatedMemory,
                .memory_stats = memoryStats,
                .create_allocator = createAllocator,
            };
        }
    };
}

fn fixedBufferAllocatorCanAlloc(self: *std.heap.FixedBufferAllocator, len: usize, alignment: std.mem.Alignment) bool {
    const ptr_align = alignment.toByteUnits();
    const adjust_off = std.mem.alignPointerOffset(self.buffer.ptr + self.end_index, ptr_align) orelse return false;
    const adjusted_index = self.end_index + adjust_off;
    const new_end_index = adjusted_index + len;
    return new_end_index <= self.buffer.len;
}

fn fixedBufferAllocatorCanFree(self: *std.heap.FixedBufferAllocator, memory: []u8, _: std.mem.Alignment) bool {
    const memory_start = @intFromPtr(memory.ptr);
    const memory_end = memory_start + memory.len;
    const buffer_start = @intFromPtr(self.buffer.ptr);
    const buffer_end = buffer_start + self.buffer.len;
    // NOTE: the first part of this predicate should suffice to determine
    // that we can free from the current allocator
    return memory_start >= buffer_start and memory_end <= buffer_end;
}

fn fixedBufferAllocatorAllocatedMemory(self: *std.heap.FixedBufferAllocator) u64 {
    return self.end_index;
}

fn fixedBufferAllocatorMemoryStats(self: *std.heap.FixedBufferAllocator, buffer: []u8) !void {
    _ = try std.fmt.bufPrint(buffer,
        \\ Type: FixedBuffer. Buffer [{x:0>16} -> {x:0>16}]. Allocated [{x:0>16} -> {x:0>16}]
    , .{
        @intFromPtr(self.buffer.ptr),
        @intFromPtr(self.buffer.ptr) + self.buffer.len,
        @intFromPtr(self.buffer.ptr),
        @intFromPtr(self.buffer.ptr) + self.end_index,
    });
}

pub fn adaptFixedBufferAllocator(alloc: std.mem.Allocator, fixed_buffer: *std.heap.FixedBufferAllocator) !*AllocatorAdapter(std.heap.FixedBufferAllocator) {
    const AdaptedAllocator = AllocatorAdapter(std.heap.FixedBufferAllocator);
    const adapter = try alloc.create(AdaptedAllocator);
    adapter.* = AdaptedAllocator.init(
        fixed_buffer,
        .{
            .can_alloc = fixedBufferAllocatorCanAlloc,
            .can_free = fixedBufferAllocatorCanFree,
            .allocated_memory = fixedBufferAllocatorAllocatedMemory,
            .memory_stats = fixedBufferAllocatorMemoryStats,
        },
    );
    return adapter;
}

pub fn adaptBuddyAllocator(comptime T: type, buddy: *T) AllocatorAdapter(T) {
    const AdaptedAllocator = AllocatorAdapter(T);
    return AdaptedAllocator.init(
        buddy,
        .{},
    );
}
