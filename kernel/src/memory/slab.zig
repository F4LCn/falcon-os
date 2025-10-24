const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const DoublyLinkedList = @import("flcn").list.DoublyLinkedList;

const log = std.log.scoped(.slab);
const CacheManagerConfig = struct {
    min_allocation_size: comptime_int = 4,
    max_allocation_size: comptime_int = 512,
};
const CacheConfig = struct {
    max_free: comptime_int = 2,
    safety: bool = builtin.mode == .Debug or builtin.mode == .ReleaseSafe,
};

const SlabList = DoublyLinkedList(Slab, .prev, .next);
const Count = u16;
const Size = u64;
pub fn CacheManager(comptime config: CacheManagerConfig) type {
    // TODO: safety measures for cache allocator
    // TODO: maybe when safety is enabled embed alloc/free after the allocator object
    // more memory waste but more safety

    const min_cache_order = std.math.log2(config.min_allocation_size);
    const max_cache_order = std.math.log2(config.max_allocation_size);
    const num_caches = max_cache_order - min_cache_order + 1;
    return struct {
        const Self = @This();
        alloc: std.mem.Allocator,
        caches: [num_caches]Cache(.{}),
        page_alloc: arch.memory.PageAllocator,

        pub fn init(alloc: std.mem.Allocator, page_alloc: arch.memory.PageAllocator) !Self {
            var self: Self = .{
                .alloc = alloc,
                .page_alloc = page_alloc,
                .caches = .{undefined} ** num_caches,
            };

            inline for (&self.caches, 0..) |*c, i| {
                const size = config.min_allocation_size * (1 << i);
                c.* = .init(size, .fromByteUnits(size));
            }

            for (&self.caches) |*c| {
                try c.create_slab(alloc, page_alloc);
            }

            return self;
        }

        pub fn _alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const aligned_size = alignment.forward(len);
            const allocation_order = std.math.log2(aligned_size);
            if (allocation_order < min_cache_order) return null;
            const cache_idx = allocation_order - min_cache_order;
            if (cache_idx >= num_caches) return null;
            return self.caches[cache_idx].allocate(self.alloc, self.page_alloc) catch unreachable;
        }

        pub fn _free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const aligned_size = alignment.forward(memory.len);
            const allocation_order = std.math.log2(aligned_size);
            if (allocation_order < min_cache_order) @panic("Bad free");
            const cache_idx = allocation_order - min_cache_order;
            if (cache_idx >= num_caches) @panic("Unexistant cache");
            self.caches[cache_idx].free(memory.ptr) catch unreachable;
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = _alloc,
                    .free = _free,
                    .remap = std.mem.Allocator.noRemap,
                    .resize = std.mem.Allocator.noResize,
                },
            };
        }
    };
}
pub fn Cache(comptime config: CacheConfig) type {
    _ = config;
    // has Slab creation data
    // has slab lists (free, partial, full)
    return struct {
        const Self = @This();
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

        pub fn init(size: u64, alignment: std.mem.Alignment) Self {
            const object_size = size;
            const required_alignment = alignment.max(.of(*anyopaque));
            const aligned_size = required_alignment.forward(object_size);
            const page_count = getPageCount(aligned_size, 4, 16);
            const objects_count: u16 = @intCast((page_count * arch.constants.default_page_size) / aligned_size);
            return .{
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
        }

        pub fn create_slab(self: *Self, alloc: std.mem.Allocator, page_allocator: arch.memory.PageAllocator) !void {
            const pages = try page_allocator.allocate(self.page_count, .{});
            log.debug("[slab#{d}] Allocated {d} pages for slab {*}", .{ self.object_size, self.page_count, pages });
            const slab = try alloc.create(Slab);
            slab.* = .{ .pages = pages, .freelist = @intFromPtr(pages) };
            self.free_list.append(slab);
            var current = slab.freelist;
            var i: u64 = 0;
            while (i < self.objects_count) : (i += 1) {
                const current_ptr: *usize = @ptrFromInt(current);
                const next = current + self.size;
                current_ptr.* = if (i < self.objects_count) next else 0;
                log.debug("[slab#{d}] freelist: {*} -> {x}", .{ self.object_size, current_ptr, next });
                current = next;
            }
        }

        pub fn allocate(self: *Self, alloc: std.mem.Allocator, page_allocator: arch.memory.PageAllocator) ![*]u8 {
            const list: *SlabList = &self.partial_list;
            if (self.partial_list.isEmpty()) {
                // log.debug("partial list empty", .{});
                if (self.free_list.isEmpty()) {
                    @branchHint(.unlikely);
                    // log.debug("free list empty", .{});
                    try self.create_slab(alloc, page_allocator);
                }
                const free_slab: ?*Slab = self.free_list.popFirst();
                if (free_slab) |f| self.partial_list.prepend(f);
            }

            var iter = list.iter();
            while (iter.next()) |slab| {
                if (slab.freelist == 0) {
                    @branchHint(.cold);
                    list.remove(slab);
                    self.full_list.prepend(slab);
                    continue;
                }
                log.debug("[slab#{d}] allocating from slab {*} freelist {x}", .{ self.object_size, slab.pages, slab.freelist });
                const typ_addr: u64 = slab.freelist;
                const free_pointer_addr = typ_addr;
                const free_pointer_ptr: *u64 = @ptrFromInt(free_pointer_addr);
                log.debug("[slab#{d}] freepointer: {*} {x}", .{self.object_size, free_pointer_ptr, free_pointer_ptr.*});
                slab.freelist = free_pointer_ptr.*;
                slab.inuse += 1;
                log.debug("[slab#{d}] allocated from slab {*} freelist {x}", .{ self.object_size, slab.pages, slab.freelist });
                if (slab.freelist == 0) {
                    @branchHint(.unlikely);
                    if (slab.inuse != self.objects_count) @panic("WTF bro");
                    list.remove(slab);
                    self.full_list.prepend(slab);
                }
                return @ptrFromInt(typ_addr);
            }
            return error.Allocate;
        }

        pub fn free(self: *Self, ptr: *anyopaque) !void {
            const ptr_addr = @intFromPtr(ptr);
            var slab: *Slab = blk: {
                var iter = self.partial_list.iter();
                while (iter.next()) |s| {
                    if (ptr_addr >= @intFromPtr(s.pages) and ptr_addr <= @intFromPtr(s.pages) + arch.constants.default_page_size * self.page_count) {
                        break :blk s;
                    }
                }

                iter = self.full_list.iter();
                while (iter.next()) |s| {
                    if (ptr_addr >= @intFromPtr(s.pages) and ptr_addr <= @intFromPtr(s.pages) + arch.constants.default_page_size * self.page_count) {
                        // NOTE: premature, but we move this slab to the partiallist because we are freeing from it
                        self.full_list.remove(s);
                        self.partial_list.append(s);
                        break :blk s;
                    }
                }
                unreachable;
            };
            const old_freepointer = slab.freelist;
            const object: *u64 = @ptrCast(@alignCast(ptr));
            object.* = old_freepointer;
            slab.freelist = ptr_addr;
            slab.inuse -= 1;
            if (slab.inuse == 0) {
                @branchHint(.unlikely);
                self.partial_list.remove(slab);
                self.free_list.prepend(slab);
            }
            // TODO: destroy free_slab beyond a given limit
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
    inuse: u64 = 0,
    freelist: u64,
    prev: ?*Self = null,
    next: ?*Self = null,
    pages: [*]align(arch.constants.default_page_size) u8,
};
