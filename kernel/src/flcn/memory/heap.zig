const std = @import("std");
const options = @import("options");
const arch = @import("arch");
const pmem = @import("pmem.zig");
const vmem = @import("vmem.zig");
const mem_allocator = @import("../allocator.zig");
const DoubleLinkedList = @import("../list.zig").DoublyLinkedList;
const Cache = @import("slab.zig");

const log = std.log.scoped(.heap);
var permanent_heap: [options.permanent_heap_size]u8 linksection(".kernel_heap") = undefined;
var kernel_heap: [options.heap_size]u8 linksection(".kernel_heap") = undefined;

var _permanent_alloc = std.heap.FixedBufferAllocator.init(@constCast(&permanent_heap));
var _kernel_alloc = std.heap.FixedBufferAllocator.init(@constCast(&kernel_heap));

pub fn permanentAllocator() std.mem.Allocator {
    return _permanent_alloc.allocator();
}

const SubHeap = struct {
    name: []const u8,
    alloc: mem_allocator.SubHeapAllocator,
    prev: ?*SubHeap = null,
    next: ?*SubHeap = null,

    pub fn init(name: []const u8, alloc: mem_allocator.SubHeapAllocator) SubHeap {
        return .{
            .name = name,
            .alloc = alloc,
        };
    }

    pub fn canAlloc(self: *SubHeap, len: usize, alignment: std.mem.Alignment) bool {
        return self.alloc.canAlloc(len, alignment);
    }

    pub fn canFree(self: *SubHeap, memory: []u8, alignment: std.mem.Alignment) bool {
        return self.alloc.canFree(memory, alignment);
    }

    pub fn allocatedMemory(self: *SubHeap) u64 {
        return self.alloc.allocatedMemory();
    }

    pub fn memoryStats(self: *SubHeap, buffer: []u8) !void {
        try self.alloc.memoryStats(buffer);
    }

    pub fn allocator(self: *SubHeap) std.mem.Allocator {
        return self.alloc.allocator();
    }
};

const SubHeapList = DoubleLinkedList(SubHeap, .prev, .next);
const CacheManager = Cache.CacheManager(.{});

const Self = @This();
virt_alloc: *vmem.VirtualAllocator,
subheaps: SubHeapList = .{},
allocated_pages: u64 = 0,
total_memory: u64 = undefined,
cache_manager: CacheManager,
// TODO: build an allocation tracking that basically lets up build a histogram of sizes/alignments
// so that we can think about optimizing our memory usage patterns

pub fn earlyInit() !Self {
    const perm_alloc = permanentAllocator();
    var heap: Self = .{
        .virt_alloc = undefined,
        .cache_manager = undefined,
    };
    const early_subheap = try perm_alloc.create(SubHeap);
    const subheap_allocator = try mem_allocator.adaptFixedBufferAllocator(perm_alloc, &_kernel_alloc);
    early_subheap.* = .init("early heap", subheap_allocator.subHeapAllocator());
    heap.subheaps.append(early_subheap);
    return heap;
}

pub fn setVmm(self: *Self, virt_alloc: *vmem.VirtualAllocator) void {
    self.total_memory = pmem.totalMemory();
    self.virt_alloc = virt_alloc;
}

pub fn init(self: *Self) !void {
    const alloc = permanentAllocator();
    const subheap = try alloc.create(SubHeap);
    self.cache_manager = try .init(self.allocator(), self.pageAllocator());
    subheap.* = .init("slab allocator", self.cache_manager.subHeapAllocator());
    self.subheaps.append(subheap);
}

pub fn printMemoryStats(self: *Self) !void {
    log.info(
        \\ Subheap: permanent allocator
        \\ Buffer [{x:0>16} -> {x:0>16}]. Used {d:0>2}%
    , .{
        @intFromPtr(Self._permanent_alloc.buffer.ptr),
        @intFromPtr(Self._permanent_alloc.buffer.ptr) + Self._permanent_alloc.buffer.len,
        Self._permanent_alloc.end_index * 100 / Self._permanent_alloc.buffer.len,
    });
    const alloc = self.allocator();
    const buffer = try alloc.alloc(u8, 2048);
    defer alloc.free(buffer);
    var iter = self.subheaps.iter();
    while (iter.next()) |subheap| {
        try subheap.memoryStats(buffer);
        log.info(
            \\ Subheap: {s}
            \\ {s}
        , .{ subheap.name, buffer });
        @memset(buffer, 0);
    }
}

// NOTE: allocatePages
// NOTE: allocateLinearRange: alloc physical page but from a virtual range with a known type
// NOTE: allocatePhysical
// TODO: on top of allocatePages build a page_allocator (std.mem.Allocator)

pub fn allocatePages(self: *Self, count: u64, args: struct { zero: bool = false, committed: bool = false }) ![*]align(arch.constants.default_page_size) u8 {
    const pmem_range = try pmem.allocatePages(count, .{ .committed = args.committed });
    self.allocated_pages += count;
    const allocated_vaddr = self.virt_alloc.physToVirt(pmem_range.start);
    const allocated_range_addr: u64 = @bitCast(allocated_vaddr);
    var allocated_ptr: [*]align(arch.constants.default_page_size) u8 = @ptrFromInt(allocated_range_addr);
    if (args.zero) {
        @memset(allocated_ptr[0 .. count * arch.constants.default_page_size], 0);
    } else {
        if (options.safety) {
            // FIXME: we should figure out how to generate and splat a known (predictable) pattern
            const u64_slice = std.mem.bytesAsSlice(u64, allocated_ptr[0 .. count * arch.constants.default_page_size]);
            @memset(u64_slice, 0xAABBCCDD11223344);
        }
    }
    return allocated_ptr;
}

pub fn freePages(self: *Self, ptr: [*]align(arch.constants.default_page_size) u8, count: u64, args: struct { committed: bool = false, poison: bool = false }) void {
    if (options.safety and args.poison) {
        // FIXME: we should figure out how to generate and splat a known (predictable) pattern
        const u64_slice = std.mem.bytesAsSlice(u64, ptr[0 .. count * arch.constants.default_page_size]);
        @memset(u64_slice, 0x99887766FFEEDDCC);
    }
    const vrange = vmem.VirtMemRange{ .start = @bitCast(@intFromPtr(ptr)), .length = count * arch.constants.default_page_size };
    const paddr = self.virt_alloc.virtToPhys(vrange.start);
    pmem.freePages(.{ .start = paddr, .length = vrange.length, .typ = .free });
    self.allocated_pages -|= count;
}

pub fn allocatedMemory(self: *Self) u64 {
    var acc: u64 = 0;
    acc += self.allocated_pages * arch.constants.default_page_size;
    var iter = self.subheaps.iter();
    while (iter.next()) |subheap| {
        acc += subheap.allocatedMemory();
    }
    return acc;
}

pub fn allocator(self: *Self) std.mem.Allocator {
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

pub fn pageAllocator(self: *Self) arch.memory.PageAllocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .allocate = _allocPages,
            .free = _freePages,
        },
    };
}

fn _alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    var subheaps_iter = self.subheaps.iter();
    while (subheaps_iter.next()) |subheap| {
        if (subheap.canAlloc(len, alignment)) {
            @branchHint(.likely);
            const subheap_alloc: std.mem.Allocator = subheap.allocator();
            return subheap_alloc.rawAlloc(len, alignment, ret_addr);
        }
    }
    log.err("could not allocate {d} bytes with alignment {d}", .{ len, alignment.toByteUnits() });
    log.err("permanent heap {d}/{d}", .{ _permanent_alloc.end_index, _permanent_alloc.buffer.len });
    log.err("early heap {d}/{d}", .{ _kernel_alloc.end_index, _kernel_alloc.buffer.len });
    return null;
}

fn _free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    var subheaps_iter = self.subheaps.iter();
    while (subheaps_iter.next()) |subheap| {
        if (subheap.canFree(memory, alignment)) {
            @branchHint(.likely);
            const subheap_alloc: std.mem.Allocator = subheap.allocator();
            subheap_alloc.rawFree(memory, alignment, ret_addr);
            return;
        }
    }
    unreachable;
}

fn _allocPages(ptr: *anyopaque, count: u64, args: arch.memory.PageAllocator.AllocateArgs) ![*]align(arch.constants.default_page_size) u8 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    // log.debug("allocating pages: {d}", .{count});
    return try self.allocatePages(count, .{ .zero = args.zero });
}

fn _freePages(ptr: *anyopaque, memory: [*]align(arch.constants.default_page_size) u8, count: u64, args: arch.memory.PageAllocator.FreeArgs) !void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    // log.debug("freeing pages: 0x{x}", .{@intFromPtr(memory)});
    self.freePages(memory, count, .{ .poison = args.poison });
}

test "Test subheap with fixed buffer allocator" {
    var buffer = [_]u8{0} ** 256;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&buffer);
    var fixed_buffer_adapter = try mem_allocator.adaptFixedBufferAllocator(std.testing.allocator, &fixed_buffer);
    defer std.testing.allocator.destroy(fixed_buffer_adapter);

    var fixed_buffer_subheap: SubHeap = .{
        .alloc = fixed_buffer_adapter.subHeapAllocator(),
        .memory_start = @intFromPtr(&buffer),
        .memory_len = buffer.len,
    };

    if (fixed_buffer_subheap.canAlloc(@sizeOf(u64) * 10, .fromByteUnits(128))) {
        const subheap_alloc = fixed_buffer_subheap.allocator();
        const allocation = try subheap_alloc.alignedAlloc(u64, .fromByteUnits(128), 10);
        defer subheap_alloc.free(allocation);
    }
}

test "Test subheap with Buddy allocator" {
    var buffer: [128]u8 align(4096) = [_]u8{0} ** 128;
    const AllocatorType = @import("../buddy2.zig").BuddyAllocator(.{});
    var underlying_allocator = try AllocatorType.init(std.testing.allocator, @intFromPtr(&buffer), buffer.len);
    defer underlying_allocator.deinit();
    var buddy_adapter = mem_allocator.adaptBuddyAllocator(AllocatorType, &underlying_allocator);

    var fixed_buffer_subheap: SubHeap = .{
        .alloc = buddy_adapter.subHeapAllocator(),
        .memory_start = @intFromPtr(&buffer),
        .memory_len = buffer.len,
    };

    if (fixed_buffer_subheap.canAlloc(@sizeOf(u64) * 10, .fromByteUnits(128))) {
        const subheap_alloc = fixed_buffer_subheap.allocator();
        const allocation = try subheap_alloc.alignedAlloc(u64, .fromByteUnits(128), 10);
        defer subheap_alloc.free(allocation);
    }
}
