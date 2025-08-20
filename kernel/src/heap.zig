const std = @import("std");
const constants = @import("constants");
const Allocator = std.mem.Allocator;

const permanent_heap: [constants.permanent_heap_size]u8 linksection(".kernel_heap") = undefined;
const kernel_heap: [constants.heap_size]u8 linksection(".kernel_heap") = undefined;

var _permanent_alloc = std.heap.FixedBufferAllocator.init(@constCast(&permanent_heap));
var _kernel_alloc = std.heap.FixedBufferAllocator.init(@constCast(&kernel_heap));

pub fn permanentAllocator() Allocator {
    return _permanent_alloc.allocator();
}

pub fn allocator() Allocator {
    return _kernel_alloc.allocator();
}
