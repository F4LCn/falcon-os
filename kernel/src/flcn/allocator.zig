const std = @import("std");
const DoublyLinkedList = @import("list.zig").DoublyLinkedList;

pub const SubHeapAllocator = struct {
    ptr: *anyopaque,
    can_alloc: *const fn (*anyopaque, usize, std.mem.Alignment) bool,
    create_allocator: *const fn (*anyopaque) std.mem.Allocator,

    pub fn canAlloc(self: *SubHeapAllocator, len: usize, alignment: std.mem.Alignment) bool {
        return self.can_alloc(self.ptr, len, alignment);
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
    if (!@hasDecl(T, "allocator")) {
        @compileError("Type " ++ T ++ " is not an allocator");
    }
    return struct {
        alloc: *T,
        can_alloc: CanAllocFn,

        pub fn init(alloc: *T, args: struct { can_alloc: ?CanAllocFn = null }) @This() {
            const can_alloc_fn = if (@hasDecl(T, "canAlloc")) blk: {
                break :blk T.canAlloc;
            } else args.can_alloc.?;

            return .{
                .alloc = alloc,
                .can_alloc = can_alloc_fn,
            };
        }

        fn canAlloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.can_alloc(self.alloc, len, alignment);
        }
        fn createAllocator(ptr: *anyopaque) std.mem.Allocator {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.alloc.allocator();
        }

        pub fn subHeapAllocator(self: *@This()) SubHeapAllocator {
            return .{
                .ptr = self,
                .can_alloc = canAlloc,
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
pub fn adaptFixedBufferAllocator(alloc: std.mem.Allocator, fixed_buffer: *std.heap.FixedBufferAllocator) !*AllocatorAdapter(std.heap.FixedBufferAllocator) {
    const AdaptedAllocator = AllocatorAdapter(std.heap.FixedBufferAllocator);
    const adapter = try alloc.create(AdaptedAllocator);
    adapter.* = AdaptedAllocator.init(
        fixed_buffer,
        .{ .can_alloc = fixedBufferAllocatorCanAlloc },
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
