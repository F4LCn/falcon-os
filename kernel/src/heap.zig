const std = @import("std");
const constants = @import("constants");
const DoubleLinkedList = @import("list.zig").DoublyLinkedList;
const buddy = @import("memory.zig").buddy;
const Allocator = @import("memory.zig").Allocator;

const permanent_heap: [constants.permanent_heap_size]u8 linksection(".kernel_heap") = undefined;
const kernel_heap: [constants.heap_size]u8 linksection(".kernel_heap") = undefined;

var _permanent_alloc = std.heap.FixedBufferAllocator.init(@constCast(&permanent_heap));
var _kernel_alloc = std.heap.FixedBufferAllocator.init(@constCast(&kernel_heap));

pub fn permanentAllocator() std.mem.Allocator {
    return _permanent_alloc.allocator();
}

pub fn allocator() std.mem.Allocator {
    return _kernel_alloc.allocator();
}

// NOTE: design goals
// 1/ 2 allocator interfaces: 1 for a basic heap allocator and the other for a page allocator
// 1.1/ We actually are going to need a "physical page" allocator
// 2/ I want this to handle memory allocation and virt mapping (for both types of allocator)
// 3/ I want the memory handled by this allocation mechanism to be growable
// 4/ We might want to start thinking about thread safety

// NOTE: ideas
// in constants.safety mode if pages dont need to be zeroed out prob write a known sequence
// allocatePhysicalPage(count, zero)
// page_allocator is simple -> call pmem.allocatePages() then call vmem.mmap -> then maybe zero out the pages if asked
// allocator() -> is hard
// build a sort of subheap list: [heap1] => [heap2] ... => [heapN]
// while !heap.can_allocate: heap = next_heap

fn adaptAllocator(alloc: std.mem.Allocator, adaptee: std.mem.Allocator, canAlloc: *const fn (*anyopaque, usize, std.mem.Alignment) bool) !Allocator {
    const vtable = try alloc.create(Allocator.VTable);
    vtable.* = .{
        .can_alloc = canAlloc,
        .alloc = adaptee.vtable.alloc,
        .free = adaptee.vtable.free,
        .resize = adaptee.vtable.resize,
        .remap = adaptee.vtable.remap,
    };
    return .{
        .ptr = adaptee.ptr,
        .vtable = vtable,
    };
}

fn testCanAllocFalse(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment) bool {
    _ = ptr;
    _ = size;
    _ = alignment;
    return false;
}

test "adapt allocator" {
    const testing_alloc = std.testing.allocator;
    var buffer: [256]u8 = .{0} ** 256;
    var fixedbuffer = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fixedbuffer.allocator();
    const adapter = try adaptAllocator(testing_alloc, alloc, testCanAllocFalse);
    defer testing_alloc.destroy(adapter.vtable);
    try std.testing.expectEqual(false, adapter.canAlloc(u8, 3));
}

fn buddyAllocator(comptime config: buddy.BuddyConfig) !Allocator {
    const Buddy = buddy.Buddy(config);
    const inner = try Buddy.init(permanentAllocator());
    return inner.allocator();
}

const SubHeap = struct {
    // For allocation we use canAlloc/canCreate to check that we can allocation with this subheap
    // For destruction we use the memory bounds of the subheap to check that the allocated
    // addr belongs to this subheap
    // addr 0xADDR [ ... ] [ .. ]

    allocator: Allocator,
    memory_start: u64,
    memory_len: u64,
};

// kernel alloc gets adapted to be the first subheap
const SubHeapList = DoubleLinkedList(SubHeap, .prev, .next);
const Heap = struct {
    subheaps: SubHeapList = .{},
    total_free_memory: u64 = 0,
    total_allocated_memory: u64 = 0,
    // TODO: build an allocation tracking that basically lets up build a histogram of sizes/alignments
    // so that we can think about optimizing our memory usage patterns
};
