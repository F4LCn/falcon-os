const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const DoublyLinkedList = @import("../list.zig").DoublyLinkedList;

const CacheConfig = struct {
    min_allocation_size: comptime_int = 4,
    max_allocation_size: comptime_int = 32 * 1024 * 1024,
    max_free: comptime_int = 2,
    safety: bool = builtin.mode == .Debug or builtin.mode == .ReleaseSafe,
};

const SlabList = DoublyLinkedList(Slab, .prev, .next);
const Count = u16;
const Size = u64;
fn Cache(comptime T: type, comptime config: CacheConfig) type {
    _ = config;
    // has Slab creation data
    // has slab lists (free, partial, full)
    const object_size = @sizeOf(T);
    const alignment: std.mem.Alignment = .of(T);
    const required_alignment = alignment.max(.of(*anyopaque));
    const aligned_size = required_alignment.forward(object_size);
    const page_count = getPageCount(aligned_size, 4, 16);
    const objects_count = (page_count * arch.constants.default_page_size) / aligned_size;
    return struct {
        const Self = @This();
        page_allocator: arch.memory.PageAllocator,
        object_size: Size,
        object_alignment: std.mem.Alignment,
        object_used_size: Size,
        size: Size,
        alignment: std.mem.Alignment,
        page_count: u16,
        objects_count: Count,
        free_list: SlabList,
        partial_list: SlabList,
        full_list: SlabList,
        free_pointer: ?*anyopaque = null,

        pub fn init(page_allocator: arch.memory.PageAllocator) !Self {
            var self: Self = .{
                .page_allocator = page_allocator,
                .object_size = object_size,
                .object_alignment = alignment,
                .object_used_size = aligned_size,
                .alignment = required_alignment,
                .size = aligned_size,
                .page_count = page_count,
                .objects_count = objects_count,
                .free_list = .{},
                .partial_list = .{},
                .full_list = .{},
            };

            try self.create_slab();

            return self;
        }

        fn create_slab(self: *Self) void {
            const pages: [*]align(arch.constants.default_page_size) u8 = try self.page_allocator.alloc(page_count);
            const slab: *Slab = @ptrCast(pages);
            self.free_list.append(slab);
        }

        pub fn allocate(self: *Self) *T {
            // if (self.free_pointer) |ptr| {
            //     @branchHint(.likely);
            //     const typ_addr: u64 = @intFromPtr(ptr);
            //     const free_pointer_addr = std.mem.alignPointer(typ_addr, @alignOf(*anyopaque));
            //     const free_pointer = @intFromPtr(free_pointer_addr);
            //     ptr.* = free_pointer.*;
            //     return @ptrFromInt(typ_addr);
            // }

            const list: *SlabList = self.partial_list;
            if (self.partial_list.isEmpty()) {
                if (self.free_list.isEmpty()) {
                    @branchHint(.unlikely);
                    self.create_slab();
                }
                const free = self.free_list.popFirst();
                self.partial_list.prepend(free);
            }

            var iter = list.iter();
            while (iter.next()) |slab| {
                const typ_addr: u64 = @intFromPtr(slab.freelist);
                const free_pointer_addr = std.mem.alignPointer(typ_addr, @alignOf(*anyopaque));
                const free_pointer: ?*anyopaque = @ptrFromInt(free_pointer_addr);
                slab.freelist = free_pointer;
                // self.free_pointer = free_pointer;
                return @ptrFromInt(typ_addr);
            }
        }

    };
}

fn getPageCount(size: Size, min_count: u64, max_waste_divisor: u16) u16 {
    var page_count: u16 = 1;
    while (true) : (page_count += 1) {
        const slab_size = page_count * arch.constants.default_page_size - @sizeOf(Slab);
        if (slab_size < min_count * size) continue;
        const wasted_size = slab_size % size;
        if (wasted_size <= slab_size / max_waste_divisor) break;
    }
    return page_count;
}

const Slab = extern struct {
    const Self = @This();
    prev: ?*Self = null,
    next: ?*Self = null,
    freelist: ?*anyopaque,
    objects: void,
};
