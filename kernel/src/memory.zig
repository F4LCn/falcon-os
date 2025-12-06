const std = @import("std");
pub const pmem = @import("memory/pmem.zig");
pub const vmem = @import("memory/vmem.zig");
const Heap = @import("memory/heap.zig");
const Cache = @import("memory/slab.zig");
const arch = @import("arch");
pub const sizes = @import("memory/sizes.zig");

// NOTE: this module is the entrypoint to everything memory related
// TODO: move all functionality that interact between pmem and vmem here

const log = std.log.scoped(.memory);

var kernel_heap: Heap = undefined;
pub var kernel_vmem: vmem.VirtualAllocator = undefined;
pub const permanent_allocator = Heap.permanentAllocator();
pub var page_allocator: arch.memory.PageAllocator = undefined;
pub const pa: arch.memory.PageAllocator = undefined;

pub fn earlyInit() !void {
    kernel_heap = try Heap.earlyInit();
    page_allocator = kernel_heap.pageAllocator();
}

pub fn init() !void {
    std.log.info("Initializing physical memory manager", .{});
    try pmem.init(permanent_allocator);
    // const range = try pmem.allocatePages(10, .{});
    // log.info("Allocated range: {any}", .{range});
    pmem.printRanges();

    arch.memory.init();

    log.info("Initializing virtual memory manager", .{});
    kernel_vmem = try vmem.init(permanent_allocator, page_allocator);
    kernel_vmem.printRanges();
    kernel_heap.setVmm(&kernel_vmem);
}

pub fn lateInit() !void {
    try kernel_heap.init();
}

pub fn allocator() std.mem.Allocator {
    return kernel_heap.allocator();
}

pub fn printStats() !void {
    try kernel_heap.printMemoryStats();
}

test {
    _ = @import("memory/pmem.zig");
    _ = @import("memory/vmem.zig");
    _ = @import("memory/heap.zig");
}
