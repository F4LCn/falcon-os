const std = @import("std");
const BootInfo = @import("bootinfo.zig").BootInfo;
const DoublyLinkedList = @import("list.zig").DoublyLinkedList;
const SpinLock = @import("synchronization.zig").SpinLock;
const mem_allocator = @import("allocator.zig");

pub const PhysRangeType = enum {
    used,
    free,
    acpi,
    reclaimable,
    bootinfo,
    framebuffer,
    kernel_module,
    paging,
    trampoline,

    pub fn fromMmapEntryType(typ: BootInfo.MmapEntry.Type) @This() {
        // TODO: make this a bit more resilient
        return @enumFromInt(@intFromEnum(typ));
    }
};
pub const PhysMemRange = struct {
    start: usize,
    length: usize,
    typ: PhysRangeType,

    pub fn format(
        self: *const @This(),
        writer: anytype,
    ) !void {
        try writer.print("{*}[0x{X} -> 0x{X} (sz={X}) {s}]", .{ self, self.start, self.start + self.length, self.length, @tagName(self.typ) });
    }
};
pub const PhysMemRangeListItem = struct {
    range: PhysMemRange,
    prev: ?*PhysMemRangeListItem = null,
    next: ?*PhysMemRangeListItem = null,

    pub fn format(
        self: *const @This(),
        writer: anytype,
    ) !void {
        try writer.print("{*}[range={f}]", .{ self, &self.range });
    }
};
pub const PhysMemRangeList = DoublyLinkedList(PhysMemRangeListItem, .prev, .next);
pub const PhysMemRangeAllocator = struct {
    // For allocation we use canAlloc/canCreate to check that we can allocation with this subheap
    // For destruction we use the memory bounds of the subheap to check that the allocated
    // addr belongs to this subheap
    // addr 0xADDR [ ... ] [ .. ]

    alloc: mem_allocator.SubHeapAllocator,
    memory_start: u64,
    memory_len: u64,
    prev: ?*PhysMemRangeAllocator = null,
    next: ?*PhysMemRangeAllocator = null,

    pub fn init(alloc: mem_allocator.SubHeapAllocator, prange: PhysMemRange) PhysMemRangeAllocator {
        return .{
            .alloc = alloc,
            .memory_start = prange.start,
            .memory_len = prange.length,
        };
    }

    pub fn canAlloc(self: *PhysMemRangeAllocator, len: usize, alignment: std.mem.Alignment) bool {
        return self.alloc.canAlloc(len, alignment);
    }

    pub fn allocator(self: *PhysMemRangeAllocator) std.mem.Allocator {
        return self.alloc.allocator();
    }
};
pub const PhysMemRangeAllocatorList = DoublyLinkedList(PhysMemRangeAllocator, .prev, .next);
pub const PhysicalMemoryManager = struct {
    const Self = @This();
    lock: SpinLock,
    memory_ranges: PhysMemRangeList,
    free_ranges: PhysMemRangeList,
    reserved_ranges: PhysMemRangeList,
    total_memory: usize,
    free_pages_count: usize,
    reserved_pages_count: usize,
    uncommitted_pages_count: usize,
    committed_pages_count: usize,
    page_allocators: PhysMemRangeAllocatorList,

    pub fn init() Self {
        return .{
            .lock = .create(),
            .memory_ranges = PhysMemRangeList{},
            .free_ranges = PhysMemRangeList{},
            .reserved_ranges = PhysMemRangeList{},
            .total_memory = 0,
            .free_pages_count = 0,
            .reserved_pages_count = 0,
            .uncommitted_pages_count = 0,
            .committed_pages_count = 0,
            .page_allocators = .{},
        };
    }
};
