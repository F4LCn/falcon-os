const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const DoublyLinkedList = @import("flcn").list.DoublyLinkedList;
const mem_allocator = @import("flcn").allocator;

const log = std.log.scoped(.slab);
const CacheManagerConfig = struct {
    min_allocation_size: comptime_int = 4,
    max_allocation_size: comptime_int = 4096,
};
const CacheConfig = struct {
    max_free: comptime_int = 2,
    safety: bool = builtin.mode == .Debug or builtin.mode == .ReleaseSafe,
};

const SlabList = DoublyLinkedList(Slab, .prev, .next);
const Count = u64;
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
            var allocation_order = std.math.log2_int_ceil(u64, aligned_size);
            // log.debug("allocation requested {d} bytes: computed order {d}", .{ len, allocation_order });
            if (allocation_order < min_cache_order) {
                allocation_order = min_cache_order;
            }
            const cache_idx = allocation_order - min_cache_order;
            if (cache_idx >= num_caches) @panic("Allocation too large");
            return self.caches[cache_idx].allocate(self.alloc, self.page_alloc) catch unreachable;
        }

        pub fn _free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const aligned_size = alignment.forward(memory.len);
            var allocation_order = std.math.log2_int_ceil(u64, aligned_size);
            // log.debug("free requested for memory {*} {d} bytes: computed order {d}", .{ memory.ptr, memory.len, allocation_order });
            if (allocation_order < min_cache_order) {
                allocation_order = min_cache_order;
            }
            const cache_idx = allocation_order - min_cache_order;
            if (cache_idx >= num_caches) @panic("Unexistant cache");
            self.caches[cache_idx].free(memory.ptr, self.alloc, self.page_alloc) catch unreachable;
        }

        fn _allocator(ptr: *anyopaque) std.mem.Allocator {
            const self: *Self = @ptrCast(@alignCast(ptr));
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

        fn _canAlloc(_: *anyopaque, _: u64, _: std.mem.Alignment) bool {
            return true;
        }

        fn _canFree(_: *anyopaque, _: []u8, _: std.mem.Alignment) bool {
            // TODO: impl this
            return true;
        }

        fn _allocatedMemory(ptr: *anyopaque) u64 {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            var acc: u64 = 0;
            for (&self.caches) |*cache| {
                var objects_count: u64 = 0;
                var iter = cache.full_list.iter();
                while (iter.next()) |_| {
                    objects_count += cache.objects_count;
                }
                iter = cache.partial_list.iter();
                while (iter.next()) |s| {
                    objects_count += s.inuse;
                }

                acc += objects_count * cache.size;
            }
            return acc;
        }

        fn _memoryStats(ptr: *anyopaque, buffer: []u8) !void {
            const self: *const Self = @ptrCast(@alignCast(ptr));
            var buf = buffer;
            for (&self.caches) |*cache| {
                var objects_count: u64 = 0;
                var iter = cache.full_list.iter();
                while (iter.next()) |_| {
                    objects_count += cache.objects_count;
                }
                iter = cache.partial_list.iter();
                while (iter.next()) |s| {
                    objects_count += s.inuse;
                }

                const written = try std.fmt.bufPrint(buf,
                    \\ Type: Slab {d}. Objects in use: {d}. Allocated size: {d}
                    \\     Free Slabs {d} Pages per slab: {d} Objects per slab {d}
                    \\
                , .{
                    cache.object_size,
                    objects_count,
                    objects_count * cache.size,
                    cache.free_list_count,
                    cache.page_count,
                    cache.objects_count,
                });
                buf = buf[written.len..];
            }
        }

        pub fn subHeapAllocator(self: *Self) mem_allocator.SubHeapAllocator {
            return .{
                .ptr = self,
                .can_alloc = _canAlloc,
                .can_free = _canFree,
                .allocated_memory = _allocatedMemory,
                .memory_stats = _memoryStats,
                .create_allocator = _allocator,
            };
        }
    };
}
pub fn Cache(comptime config: CacheConfig) type {
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
        free_list_count: u16,
        partial_list: SlabList,
        full_list: SlabList,

        pub fn init(size: u64, alignment: std.mem.Alignment) Self {
            const object_size = size;
            const required_alignment = alignment.max(.of(*anyopaque));
            const aligned_size = required_alignment.forward(object_size);
            const page_count = getPageCount(aligned_size, 4, 16);
            const objects_count: Count = @intCast((@as(Count, @intCast(page_count)) * arch.constants.default_page_size) / aligned_size);
            return .{
                .object_size = object_size,
                .object_alignment = alignment,
                .object_used_size = aligned_size,
                .alignment = required_alignment,
                .size = aligned_size,
                .page_count = page_count,
                .objects_count = objects_count,
                .free_list = .{},
                .free_list_count = 0,
                .partial_list = .{},
                .full_list = .{},
            };
        }

        pub fn create_slab(self: *Self, alloc: std.mem.Allocator, page_alloc: arch.memory.PageAllocator) !void {
            const pages = try page_alloc.allocate(self.page_count, .{});
            // log.debug("[slab#{d}] Allocated {d} pages for slab {*}", .{ self.object_size, self.page_count, pages });
            const slab = try alloc.create(Slab);
            slab.* = .{ .pages = pages, .freelist = @intFromPtr(pages) };
            self.free_list.append(slab);
            self.free_list_count += 1;
            var current = slab.freelist;
            var i: u64 = 0;
            while (i < self.objects_count) : (i += 1) {
                const current_ptr: *usize = @ptrFromInt(current);
                const next = current + self.size;
                current_ptr.* = if (i < self.objects_count - 1) next else 0;
                // log.debug("[slab#{d}] freelist: {*} -> {x}", .{ self.object_size, current_ptr, current_ptr.* });
                current = next;
            }
        }

        fn cull_slabs(self: *Self, alloc: std.mem.Allocator, page_alloc: arch.memory.PageAllocator) !void {
            // TODO: some logic to better chose which slab to cull
            const slabs_to_cull = self.free_list_count - config.max_free;
            // log.info("culling {d} free slabs", .{slabs_to_cull});
            var i = slabs_to_cull;
            while (i > 0) : (i -= 1) {
                const free_slab = self.free_list.pop();
                if (free_slab) |slab| {
                    try page_alloc.free(slab.pages, self.page_count, .{});
                    alloc.destroy(slab);
                }
            }
            self.free_list_count -= slabs_to_cull;
            // log.info("culled {d} free slabs, remaining {d}", .{ slabs_to_cull, self.free_list_count });
        }

        pub fn allocate(self: *Self, alloc: std.mem.Allocator, page_alloc: arch.memory.PageAllocator) ![*]u8 {
            const list: *SlabList = &self.partial_list;
            if (self.partial_list.isEmpty()) {
                // log.debug("partial list empty", .{});
                if (self.free_list.isEmpty()) {
                    @branchHint(.unlikely);
                    std.debug.assert(self.free_list_count == 0);
                    // log.debug("free list empty", .{});
                    try self.create_slab(alloc, page_alloc);
                }
                const free_slab: ?*Slab = self.free_list.popFirst();
                if (free_slab) |f| {
                    self.free_list_count -= 1;
                    self.partial_list.prepend(f);
                } else {
                    unreachable;
                }
            }

            var iter = list.iter();
            while (iter.next()) |slab| {
                if (slab.freelist == 0) {
                    @branchHint(.cold);
                    list.remove(slab);
                    self.full_list.prepend(slab);
                    continue;
                }
                // log.debug("[slab#{d}] allocating from slab {*} freelist {x}", .{ self.object_size, slab.pages, slab.freelist });
                const typ_addr: u64 = slab.freelist;
                const free_pointer_addr = typ_addr;
                const free_pointer_ptr: *u64 = @ptrFromInt(free_pointer_addr);
                // log.debug("[slab#{d}] freepointer: {*} {x}", .{ self.object_size, free_pointer_ptr, free_pointer_ptr.* });
                slab.freelist = free_pointer_ptr.*;
                slab.inuse += 1;
                // log.debug("[slab#{d}] allocated from slab {*} freelist {x} inuse{d} free lists{d}", .{ self.object_size, slab.pages, slab.freelist, slab.inuse, self.free_list_count });
                if (slab.freelist == 0) {
                    @branchHint(.unlikely);
                    if (slab.inuse != self.objects_count) {
                        log.err("Expected inuse:{d} == objects_count:{d}", .{ slab.inuse, self.objects_count });
                        unreachable;
                    }
                    list.remove(slab);
                    self.full_list.prepend(slab);
                }
                return @ptrFromInt(typ_addr);
            }
            return error.Allocate;
        }

        pub fn free(self: *Self, ptr: *anyopaque, alloc: std.mem.Allocator, page_alloc: arch.memory.PageAllocator) !void {
            const ptr_addr = @intFromPtr(ptr);
            var slab: *Slab = blk: {
                var iter = self.partial_list.iter();
                while (iter.next()) |s| {
                    // log.debug("free: checking partial slab {*} ({x})", .{ s.pages, self.page_count });
                    if (ptr_addr >= @intFromPtr(s.pages) and ptr_addr <= @intFromPtr(s.pages) + arch.constants.default_page_size * @as(u64, @intCast(self.page_count))) {
                        // log.debug("found slab to free from in partial list {*}", .{s.pages});
                        break :blk s;
                    }
                }

                iter = self.full_list.iter();
                while (iter.next()) |s| {
                    // log.debug("free: checking full slab {*}", .{s.pages});
                    if (ptr_addr >= @intFromPtr(s.pages) and ptr_addr <= @intFromPtr(s.pages) + arch.constants.default_page_size * self.page_count) {
                        // NOTE: premature, but we move this slab to the partial list because we are freeing from it
                        self.full_list.remove(s);
                        self.partial_list.append(s);
                        // log.debug("free: partial list tail {*} {*}", .{ self.partial_list.tail.?.prev, self.partial_list.tail.?.next });
                        // log.debug("found slab to free from in full list, moved to partial {*} {*}", .{ s, s.pages });
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
            // log.debug("[slab#{d}] freed from slab {*} freelist {x} inuse {d}", .{ self.object_size, slab.pages, slab.freelist, slab.inuse });
            if (slab.inuse == 0) {
                @branchHint(.unlikely);
                // log.debug("[slab#{d}] moving slab {*} to free_list", .{ self.object_size, slab.pages });
                self.partial_list.remove(slab);
                self.free_list.prepend(slab);
                self.free_list_count += 1;
            }

            if (self.free_list_count > config.max_free) try self.cull_slabs(alloc, page_alloc);
        }
    };
}

fn getPageCount(size: Size, min_count: u64, max_waste_divisor: u16) u16 {
    var page_count: u64 = 1;
    while (true) : (page_count += 1) {
        const slab_size = page_count * arch.constants.default_page_size - @sizeOf(Slab);
        if (slab_size < min_count * size) continue;
        const wasted_size = slab_size % size;
        if (wasted_size <= slab_size / max_waste_divisor) break;
    }
    return @intCast(page_count);
}

const Slab = extern struct {
    const Self = @This();
    inuse: u64 = 0,
    freelist: u64,
    prev: ?*Self = null,
    next: ?*Self = null,
    pages: [*]align(arch.constants.default_page_size) u8,
};
