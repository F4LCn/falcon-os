const std = @import("std");
const pmem = @import("memory/pmem.zig");
const vmem = @import("memory/vmem.zig");
const Heap = @import("memory/heap.zig");
pub const sizes = @import("memory/sizes.zig");

// NOTE: this module is the entrypoint to everything memory related
// TODO: move all functionality that interact between pmem and vmem here

const log = std.log.scoped(.memory);

var kernel_heap: Heap = undefined;
pub var kernel_vmem: vmem.VirtualAllocator = undefined;
pub const permanent_allocator = Heap.permanentAllocator();

pub fn earlyInit() !void {
    kernel_heap = try Heap.earlyInit();
}

pub fn init() !void {
    std.log.info("Initializing physical memory manager", .{});
    try pmem.init(permanent_allocator);
    const range = try pmem.allocatePages(10, .{});
    log.info("Allocated range: {any}", .{range});
    pmem.printRanges();

    log.info("Initializing virtual memory manager", .{});
    kernel_vmem = try vmem.init(permanent_allocator);
    kernel_vmem.printRanges();
    kernel_heap.setVmm(&kernel_vmem);
}

pub fn lateInit() !void {
    try kernel_heap.extend(200 * sizes.mb);
}

pub fn allocator() std.mem.Allocator {
    return kernel_heap.allocator();
}

pub fn pageAllocator() std.mem.Allocator {
    return kernel_heap.pageAllocator();
}


pub fn printStats() void {
    log.debug(
        \\
        \\ Kernel allocator stats:
        \\      - Free Mem: {d}
        \\      - Allocated Mem: {d}
        \\      - Total Mem: {d}
    , .{ kernel_heap.total_free_memory, kernel_heap.total_allocated_memory, kernel_heap.total_allocated_memory + kernel_heap.total_free_memory });
}

test {
    _ = @import("memory/pmem.zig");
    _ = @import("memory/vmem.zig");
    _ = @import("memory/buddy.zig");
    _ = @import("memory/heap.zig");
}
