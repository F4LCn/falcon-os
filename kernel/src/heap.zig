const std = @import("std");
const constants = @import("constants");
const DoubleLinkedList = @import("list.zig").DoublyLinkedList;
const mem = @import("memory.zig");
const arch = @import("arch");

var permanent_heap: [constants.permanent_heap_size]u8 linksection(".kernel_heap") = undefined;
var kernel_heap: [constants.heap_size]u8 linksection(".kernel_heap") = undefined;

var _permanent_alloc = std.heap.FixedBufferAllocator.init(@constCast(&permanent_heap));
var _kernel_alloc = std.heap.FixedBufferAllocator.init(@constCast(&kernel_heap));

pub fn permanentAllocator() std.mem.Allocator {
    return _permanent_alloc.allocator();
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

const SubHeap = struct {
    // For allocation we use canAlloc/canCreate to check that we can allocation with this subheap
    // For destruction we use the memory bounds of the subheap to check that the allocated
    // addr belongs to this subheap
    // addr 0xADDR [ ... ] [ .. ]

    alloc: mem.allocator.SubHeapAllocator,
    memory_start: u64,
    memory_len: u64,
    prev: ?*SubHeap = null,
    next: ?*SubHeap = null,

    pub fn initFromSlice(alloc: mem.allocator.SubHeapAllocator, memory: []u8) SubHeap {
        return .{
            .alloc = alloc,
            .memory_start = @intFromPtr(memory.ptr),
            .memory_len = memory.len,
        };
    }

    pub fn canAlloc(self: *SubHeap, len: usize, alignment: std.mem.Alignment) bool {
        return self.alloc.canAlloc(len, alignment);
    }

    pub fn allocator(self: *SubHeap) std.mem.Allocator {
        return self.alloc.allocator();
    }
};

// TODO: kernel alloc gets adapted to be the first subheap
const SubHeapList = DoubleLinkedList(SubHeap, .prev, .next);

const Self = @This();
vmm: *mem.vmem.VMem,
subheaps: SubHeapList = .{},
total_free_memory: u64 = 0,
total_allocated_memory: u64 = 0,
// TODO: build an allocation tracking that basically lets up build a histogram of sizes/alignments
// so that we can think about optimizing our memory usage patterns

pub fn earlyInit() !Self {
    const perm_alloc = permanentAllocator();
    var heap: Self = .{ .vmm = undefined };
    const early_subheap = try perm_alloc.create(SubHeap);
    const subheap_allocator = try mem.allocator.adaptFixedBufferAllocator(perm_alloc, &_kernel_alloc);
    early_subheap.* = .initFromSlice(subheap_allocator.subHeapAllocator(), &kernel_heap);
    heap.subheaps.append(early_subheap);
    heap.total_free_memory += kernel_heap.len;
    return heap;
}
pub fn setVmm(self: *Self, vmm: *mem.vmem.VMem) void {
    self.vmm = vmm;
}

// NOTE: allocatePages
// NOTE: allocateLinearRange: alloc physical page but from a virtual range with a known type
// NOTE: allocatePhysical
// TODO: on top of allocatePages build a page_allocator (std.mem.Allocator)

pub fn allocatePages(self: *Self, count: u64, args: struct { zero: bool = false, committed: bool = false }) ![*]align(arch.constants.default_page_size) u8 {
    const pmem_range = try mem.pmem.allocatePages(count, .{ .committed = args.committed });
    const vmem_range = try self.vmm.allocateRange(count, .{});
    try self.vmm.mmap(pmem_range, vmem_range, mem.vmem.DefaultMmapFlags);
    const allocated_range_addr: u64 = @bitCast(vmem_range.start);
    var allocated_ptr: [*]align(arch.constants.default_page_size) u8 = @ptrFromInt(allocated_range_addr);
    if (args.zero) {
        @memset(allocated_ptr[0 .. count * arch.constants.default_page_size], 0);
    } else {
        if (constants.safety) {
            // FIXME: we should figure out how to generate and splat a known (predictable) pattern
            const u128_slice = std.mem.bytesAsSlice(u64, allocated_ptr[0 .. count * arch.constants.default_page_size]);
            @memset(u128_slice, 0xAABBCCDD11223344);
        }
    }
    return allocated_ptr;
}

// TODO: (opt.) expose buddy min allocation size
pub fn extend(self: *Self, len: u64) !void {
    const alloc = permanentAllocator();
    const subheap = try alloc.create(SubHeap);
    const buddy_allocator = try alloc.create(mem.buddy.Buddy(.{}));

    const page_aligned_len = std.mem.alignBackward(u64, len, arch.constants.default_page_size);
    const page_count = @divExact(page_aligned_len, arch.constants.default_page_size);
    const memory = try self.allocatePages(page_count, .{});
    const memory_slice = memory[0 .. page_count * arch.constants.default_page_size];
    buddy_allocator.* = try .init(alloc, memory_slice);
    subheap.* = .{
        .memory_start = @intFromPtr(memory_slice.ptr),
        .memory_len = memory_slice.len,
        .alloc = buddy_allocator.subHeapAllocator(),
    };
    self.subheaps.append(subheap);
    self.total_free_memory += memory_slice.len;
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
    return null;
}

fn _free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    var subheaps_iter = self.subheaps.iter();
    const memory_ptr = @intFromPtr(memory.ptr);
    while (subheaps_iter.next()) |subheap| {
        const subheap_mem_start = subheap.memory_start;
        const subheap_mem_end = subheap_mem_start + subheap.memory_len;
        if (subheap_mem_start <= memory_ptr and memory_ptr <= subheap_mem_end) {
            @branchHint(.likely);
            const subheap_alloc: std.mem.Allocator = subheap.allocator();
            subheap_alloc.rawFree(memory, alignment, ret_addr);
            return;
        }
    }
    unreachable;
}

test "Test subheap with fixed buffer allocator" {
    var buffer = [_]u8{0} ** 256;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&buffer);
    var fixed_buffer_adapter = mem.allocator.adaptFixedBufferAllocator(&fixed_buffer);

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
    const AllocatorType = mem.buddy.Buddy(.{});
    var underlying_allocator = try AllocatorType.init(std.testing.allocator, &buffer);
    defer underlying_allocator.deinit();
    var buddy_adapter = mem.allocator.adaptBuddyAllocator(AllocatorType, &underlying_allocator);

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
