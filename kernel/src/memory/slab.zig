const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const DoublyLinkedList = @import("flcn").list.DoublyLinkedList;

const log = std.log.scoped(.slab);
const CacheConfig = struct {
    min_allocation_size: comptime_int = 4,
    max_allocation_size: comptime_int = 32 * 1024 * 1024,
    max_free: comptime_int = 2,
    safety: bool = builtin.mode == .Debug or builtin.mode == .ReleaseSafe,
};

const SlabList = DoublyLinkedList(Slab, .prev, .next);
const Count = u16;
const Size = u64;
pub fn Cache(comptime T: type, comptime config: CacheConfig) type {
    _ = config;
    // has Slab creation data
    // has slab lists (free, partial, full)
    const object_size = @sizeOf(T);
    const alignment: std.mem.Alignment = .of(T);
    const required_alignment = alignment.max(.of(*anyopaque));
    const aligned_size = required_alignment.forward(object_size);
    const page_count = getPageCount(aligned_size, 4, 8);
    const objects_count = (page_count * arch.constants.default_page_size) / aligned_size;
    return struct {
        const Self = @This();
        alloc: std.mem.Allocator,
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
        // free_pointer: ?*anyopaque = null,

        pub fn init(alloc: std.mem.Allocator, page_allocator: arch.memory.PageAllocator) !Self {
            var self: Self = .{
                .alloc = alloc,
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

        fn create_slab(self: *Self) !void {
            log.debug("Allocating {d} pages for slab", .{page_count});
            const pages: [*]allowzero align(arch.constants.default_page_size) u8 = try self.page_allocator.allocate(page_count, .{});
            log.debug("Allocated {d} pages for slab {*}", .{ page_count, pages });
            const slab = try self.alloc.create(Slab);
            slab.* = .{ .pages = pages, .freelist = @intFromPtr(pages) };
            self.free_list.append(slab);
            var current = slab.freelist;
            var i: u64 = 0;
            log.debug("setting up freelist", .{});
            while (i < objects_count) : (i += 1) {
                const current_ptr: *usize = @ptrFromInt(current);
                const next = current + aligned_size;
                current_ptr.* = if (i < objects_count) next else 0;
                current = next;
            }
        }

        pub fn allocate(self: *Self) !*T {
            // if (self.free_pointer) |ptr| {
            //     @branchHint(.likely);
            //     const typ_addr: u64 = @intFromPtr(ptr);
            //     const free_pointer_addr = std.mem.alignPointer(typ_addr, @alignOf(*anyopaque));
            //     const free_pointer = @intFromPtr(free_pointer_addr);
            //     ptr.* = free_pointer.*;
            //     return @ptrFromInt(typ_addr);
            // }

            const list: *SlabList = &self.partial_list;
            if (self.partial_list.isEmpty()) {
                log.debug("partial list empty", .{});
                if (self.free_list.isEmpty()) {
                    @branchHint(.unlikely);
                    log.debug("free list empty", .{});
                    try self.create_slab();
                }
                const free = self.free_list.popFirst();
                if (free) |f| self.partial_list.prepend(f);
            }

            var iter = list.iter();
            while (iter.next()) |slab| {
                log.debug("allocating from slab {*} freelist {x}", .{slab.pages, slab.freelist});
                const typ_addr: u64 = slab.freelist;
                const free_pointer_addr = typ_addr;
                const free_pointer_ptr: *u64 = @ptrFromInt(free_pointer_addr);
                slab.freelist = free_pointer_ptr.*;
                if(slab.freelist == 0) {
                    list.remove(slab);
                    self.full_list.prepend(slab);
                }
                // self.free_pointer = free_pointer;
                return @ptrFromInt(typ_addr);
            }
            return error.Allocate;
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
    pages: [*]allowzero align(arch.constants.default_page_size) u8,
    freelist: u64,
};
