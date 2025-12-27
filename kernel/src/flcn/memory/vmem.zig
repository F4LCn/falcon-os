const std = @import("std");
const options = @import("options");
const arch = @import("arch");
const Allocator = std.mem.Allocator;
const sizes = @import("sizes.zig");
const DoublyLinkedList = @import("../list.zig").DoublyLinkedList;
const SpinLock = @import("../synchronization.zig").SpinLock;
const vmem_manager = @import("../vmm.zig");

// TODO: make this great again
const pmem = @import("pmem.zig");

const log = std.log.scoped(.vmem);
const Error = error{OutOfVirtMemory};

pub const VAddrSize = arch.memory.VAddrSize;
pub const VAddr = arch.memory.VAddr;
const MmapFlags = arch.memory.Flags;
pub const DefaultFlags: MmapFlags = arch.memory.DefaultFlags;
const PageMapping = arch.memory.PageMapping;

pub const VirtMemRange = arch.memory.VirtMemRange;
pub const VirtRangeType = vmem_manager.VirtRangeType;
pub const MMapArgs = arch.memory.MMapArgs;

const VirtualMemoryManager = arch.memory.VirtualMemoryManager;
const PlatformVirtualMapper = arch.memory.PageMapManager;

pub const VirtualAllocator = @This();
impl: PlatformVirtualMapper,
vmm: VirtualMemoryManager,

extern const _kernel_end: u64;
extern const fb: u64;

pub fn init(alloc: Allocator, page_allocator: arch.memory.PageAllocator) !VirtualAllocator {
    var vmm = VirtualMemoryManager.init(alloc);
    const inner: PlatformVirtualMapper = try .init(page_allocator);

    const quickmap_start = @intFromPtr(&_kernel_end) + 2 * arch.constants.default_page_size;
    const quickmap_length = arch.constants.default_page_size * options.max_cpu;
    vmm.quickmap.start = @bitCast(quickmap_start);
    vmm.quickmap.length = quickmap_length;

    const stack_start = -%(@as(u64, arch.constants.default_page_size) * options.max_cpu);
    const quickmap_pt_entry_length = std.mem.alignForward(u64, options.max_cpu * @sizeOf(PageMapping.Entry), arch.constants.default_page_size);
    const quickmap_pt_entry_start = stack_start - quickmap_pt_entry_length - 2 * arch.constants.default_page_size;
    vmm.quickmap_pt_entry.start = @bitCast(quickmap_pt_entry_start);
    vmm.quickmap_pt_entry.length = quickmap_pt_entry_length;

    // NOTE: kernel memory map (N = cpu count, padding = 2 pages)
    // HIGH_MEM_LIMIT    unused                   (0xffff800000000000 => 0xffff880000000000)
    // -120tb            direct mapping           (0xffff880000000000 => 0xffffc80000000000)
    // -56tb             free area                (0xffffc80000000000 => 0xffffffff80000000)
    //  -2g              boot header structure    (0xffffffff80000000 => 0xffffffff80001000)
    //  -2g+1p           environment string       (0xffffffff80001000 => 0xffffffff80002000)
    //  -2g+2p           kernel code              (0xffffffff80002000 => 0xffffffff80002000 + kernel_size)
    //  -2g+2p+ks+2p     quickmap start           (0xffffffff80002000 + kernel_size + padding => 0xfffffffffc002000 + kernel_size + padding + N * 0x1000)
    // -256m             "mmio" area              (0xfffffffff0000000 => 0xfffffffff8000000)
    // -128m             "fb" framebuffer         (0xfffffffff8000000 => 0xfffffffffc000000)
    //                       .......
    //                   quickmap pte             (stack_end - sizeof(PTE) * N - padding => stack_end - padding)
    //                   stack start (cpuN)       (-N * 0x1000 => -(N-1) * 0x1000)
    //                       ......
    //                   stack start (cpu1)       (0xffffffffffffe000 => 0xfffffffffffff000)
    //    0              stack start (cpu0)       (0xfffffffffffff000 => 0x0000000000000000)
    //                      ......
    //  0-1m             ram identity mapped      (0x0000000000000000 => 0x0000000000100000)

    log.debug("registering ranges", .{});
    {
        vmm.lock.lock();
        defer vmm.lock.unlock();
        try vmm.registerRange(0xfffffffff0000000, 128 * sizes.mb, .{ .typ = .mmio });
        try vmm.registerRange(@intFromPtr(&fb), 64 * sizes.mb, .{ .typ = .framebuffer });
        const kernel_range_start = 0xffffffff80000000;
        const kernel_end_addr = @intFromPtr(&_kernel_end);
        const kernel_range_size = kernel_end_addr -% kernel_range_start;
        log.debug("kernel size: {x}", .{kernel_range_size});

        try vmm.registerRange(kernel_range_start, kernel_range_size, .{ .typ = .kernel, .frozen = true });
        const stack_size = options.max_cpu * arch.constants.default_page_size;
        log.debug("stack start: {x} size: {x}", .{ stack_start, stack_size });
        try vmm.registerRange(stack_start, stack_size, .{ .typ = .stack });
        try vmm.registerRange(0x100000, 0x400000 - 0x101000, .{ .typ = .low_kernel });
        try vmm.registerRange(quickmap_pt_entry_start, quickmap_pt_entry_length, .{ .typ = .quickmap_pte });
        try vmm.registerRange(quickmap_start, quickmap_length, .{ .typ = .quickmap });
        const quickmap_end = quickmap_start + quickmap_length;
        try vmm.registerRange(quickmap_end + 2 * arch.constants.default_page_size, quickmap_pt_entry_start - quickmap_end - 4 * arch.constants.default_page_size, .{});
        // try vmm.registerRange(0xffffffff88000000, 0xfffffffff0000000 - 0xffffffffc0000000, .{});
    }
    var self: VirtualAllocator = .{ .impl = inner, .vmm = vmm };

    // unmap nullptr page
    self.munmap(
        .{
            .start = @bitCast(@as(u64, 0)),
            .length = arch.constants.default_page_size,
        },
    );

    return self;
}

pub fn printRanges(self: *const @This()) void {
    for (self.vmm.memory_map, 0..) |range_list, typ_idx| {
        const typ: VirtRangeType = @enumFromInt(typ_idx);
        var iter = range_list.iter();
        log.debug("{t} virtual ranges", .{typ});
        while (iter.next()) |list_item| {
            log.debug("{f}", .{list_item});
        }
    }
}

pub fn reserveRange(self: *VirtualAllocator, start: u64, length: u64, typ: VirtRangeType) !void {
    // reserved a free range (moves the range from free_ranges to reserved_ranges)
    try self.vmm.reserveRange(start, length, .free, typ);
}

const VirtualAllocArgs = struct { typ: ?VirtRangeType = null };

pub fn allocateRange(self: *VirtualAllocator, count: u64, args: VirtualAllocArgs) !VirtMemRange {
    const length = count * arch.constants.default_page_size;
    return try self.vmm.allocateRange(length, .{ .typ = args.typ });
}

pub fn freeRange(self: *VirtualAllocator, vrange: VirtMemRange, args: VirtualAllocArgs) void {
    _ = self; // autofix
    _ = vrange; // autofix
    _ = args; // autofix
    // the only cases we should have here are:
    // - we create a new range
    // - we extend an existing range (change start or length but not both)
    // all other cases should be errors
}

pub fn mmap(self: *VirtualAllocator, prange: pmem.PhysMemRange, vrange: VirtMemRange, flags: MmapFlags, args: MMapArgs) !void {
    log.debug("mapping prange {f} to vrange {f} (flags={any}, args={any})", .{ prange, vrange, flags, args });
    try self.impl.mmap(prange, vrange, flags, args);
}

pub fn munmap(self: *VirtualAllocator, vrange: VirtMemRange) void {
    log.debug("unmapping vrange {f}", .{vrange});
    self.impl.munmap(vrange);
}

pub fn mremap(self: *VirtualAllocator, prange: pmem.PhysMemRange, vrange: VirtMemRange, flags: MmapFlags) !void {
    log.debug("remapping prange {f} to vrange {f} (flags={any})", .{ prange, vrange, flags });
    try self.impl.mmap(prange, vrange, flags, .{ .remap = true });
}

pub fn mremap2(self: *VirtualAllocator, vrange: VirtMemRange, flags: MmapFlags) !void {
    log.debug("remapping vrange {f} (flags={any})", .{ vrange, flags });
    try self.impl.remap(vrange, flags);
}

pub fn virtToPhys(self: *VirtualAllocator, vaddr: VAddr) arch.memory.PAddr {
    return self.impl.virtToPhys(vaddr);
}

pub fn physToVirt(self: *VirtualAllocator, paddr: arch.memory.PAddr) VAddr {
    return self.impl.physToVirt(paddr);
}
