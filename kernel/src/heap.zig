const std = @import("std");
const Allocator = std.mem.Allocator;

const PERMANENT_HEAP_SIZE = 1 * 1024 * 1024;
const KERNEL_HEAP_SIZE = 4 * 1024 * 1024;

const permanent_heap: [PERMANENT_HEAP_SIZE]u8 linksection(".kernel_heap") = undefined;
const kernel_heap: [KERNEL_HEAP_SIZE]u8 linksection(".kernel_heap") = undefined;

var _permanent_alloc = std.heap.FixedBufferAllocator.init(@constCast(&permanent_heap));
var _kernel_alloc = std.heap.FixedBufferAllocator.init(@constCast(&kernel_heap));

pub fn permanentAllocator() Allocator {
    return _permanent_alloc.allocator();
}

pub fn allocator() Allocator {
    return _kernel_alloc.allocator();
}
