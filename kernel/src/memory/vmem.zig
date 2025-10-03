const std = @import("std");
const constants = @import("constants");
const arch = @import("arch");
const SpinLock = @import("../synchronization.zig").SpinLock;
const DoublyLinkedList = @import("../list.zig").DoublyLinkedList;
const Allocator = std.mem.Allocator;
const sizes = @import("sizes.zig");

// TODO: make this great again
const pmem = @import("pmem.zig");

const log = std.log.scoped(.vmem);
const Error = error{OutOfVirtMemory};

pub const VAddrSize = arch.memory.VAddrSize;
pub const VAddr = arch.memory.VAddr;
const MmapFlags = arch.memory.MmapFlags;
pub const DefaultMmapFlags: MmapFlags = arch.memory.DefaultMmapFlags;
const PageMapping = arch.memory.PageMapping;

const VirtRangeType = enum(u8) {
    mmio,
    framebuffer,
    kernel,
    low_kernel,
    stack,
    quickmap,
    quickmap_pte,
    free,
};

const VirtMemRange = struct {
    start: VAddr,
    length: u64,
    typ: ?VirtRangeType = null,

    pub fn format(
        self: *const @This(),
        writer: *std.Io.Writer,
    ) !void {
        const start_addr = @as(u64, @bitCast(self.start));
        if (self.typ) |typ| {
            try writer.print("{*}[0x{X} -> 0x{X} (sz={X}) {s}]", .{ self, start_addr, start_addr +% self.length, self.length, @tagName(typ) });
        } else {
            try writer.print("{*}[0x{X} -> 0x{X} (sz={X}) free]", .{ self, start_addr, start_addr +% self.length, self.length });
        }
    }
};
const VirtMemRangeListItem = struct {
    const Self = @This();
    range: VirtMemRange,
    prev: ?*Self = null,
    next: ?*Self = null,

    pub fn format(
        self: *const @This(),
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{*}[range={f}]", .{ self, &self.range });
    }
};
const VirtMemRangeList = DoublyLinkedList(VirtMemRangeListItem, .prev, .next);
pub const VirtualMemoryManager = struct {
    const num_range_slots = std.enums.directEnumArrayLen(VirtRangeType, 0);

    alloc: Allocator,
    lock: SpinLock,
    memory_map: [num_range_slots]VirtMemRangeList,
    free_ranges: VirtMemRangeList,
    reserved_ranges: VirtMemRangeList,
    quickmap_pt_entry: VirtMemRange,
    quickmap: VirtMemRange,

    pub fn init(alloc: Allocator) VirtualMemoryManager {
        const zero: u64 = 0;
        return .{
            .lock = .create(),
            .alloc = alloc,
            .memory_map = [_]VirtMemRangeList{.{}} ** num_range_slots,
            .free_ranges = VirtMemRangeList{},
            .reserved_ranges = VirtMemRangeList{},
            .quickmap_pt_entry = .{ .start = @bitCast(zero), .length = 0, .typ = .quickmap_pte },
            .quickmap = .{ .start = @bitCast(zero), .length = 0, .typ = .quickmap },
        };
    }

    const RangeArgs = struct {
        typ: ?VirtRangeType = null,
    };

    pub fn registerRange(self: *VirtualMemoryManager, start: VAddrSize, length: u64, args: RangeArgs) !void {
        log.debug("registering range 0x{x} ({d})", .{ start, length });
        const end = start +% length;
        const typ = args.typ orelse .free;
        const range_list = &self.memory_map[@intFromEnum(typ)];
        var iter = range_list.iter();
        var prev_opt: ?*VirtMemRangeListItem = null;
        var next_opt: ?*VirtMemRangeListItem = null;
        while (iter.next()) |item| {
            const range = &item.range;
            log.debug("checking range: {f}", .{range});
            const range_start = @as(VAddrSize, @bitCast(range.start));
            // const range_end = range_start +% range.length;
            if (range_start <= start) {
                prev_opt = item;
                next_opt = item.next;
                break;
            } else {
                next_opt = item;
                break;
            }
        }

        if (prev_opt == null and next_opt == null) {
            // This should only happen if no ranges are present
            std.debug.assert(range_list.head == null and range_list.tail == null);
            const range_item = try self.alloc.create(VirtMemRangeListItem);
            range_item.* = .{
                .range = .{
                    .start = @bitCast(start),
                    .length = length,
                    .typ = typ,
                },
            };
            range_list.append(range_item);
        } else if (prev_opt == null) {
            const n = next_opt.?; // Safety: we know this is non-null
            const n_range = &n.range;
            const n_start = @as(VAddrSize, @bitCast(n_range.start));
            if (n_start <= end) {
                const overlap_length = end - n_start;
                n_range.start = @bitCast(start);
                n_range.length += length - overlap_length;
                return;
            }
            const range_item = try self.alloc.create(VirtMemRangeListItem);
            range_item.* = .{
                .range = .{
                    .start = @bitCast(start),
                    .length = length,
                    .typ = typ,
                },
            };
            range_list.insertBefore(n, range_item);
        } else {
            const p = prev_opt.?; // Safety: we know this is non-null
            const p_range = &p.range;
            const p_start = @as(VAddrSize, @bitCast(p_range.start));
            const p_end = p_start +% p_range.length;
            if (p_end >= start) {
                const overlap_length = p_end - start;
                p_range.length += length - overlap_length;
                if (next_opt) |n| {
                    const n_range = &n.range;
                    const n_start = @as(VAddrSize, @bitCast(n_range.start));
                    const new_p_end = p_start +% p_range.length;
                    if (new_p_end >= n_start) {
                        const pn_overlap_length = new_p_end - n_start;
                        p_range.length += n_range.length - pn_overlap_length;
                        range_list.remove(n);
                        defer self.alloc.destroy(n);
                    }
                }
                return;
            }
            const range_item = try self.alloc.create(VirtMemRangeListItem);
            range_item.* = .{
                .range = .{
                    .start = @bitCast(start),
                    .length = length,
                    .typ = typ,
                },
            };
            range_list.insertAfter(p, range_item);
        }
    }

    pub fn reserveRange(self: *VirtualMemoryManager, start: VAddrSize, length: u64, src_args: RangeArgs, dst_typ: VirtRangeType) !void {
        const end = start +% length;
        const src_typ = src_args.typ orelse .free;
        const free_ranges_list = &self.memory_map[@intFromEnum(src_typ)];
        var iter = free_ranges_list.iter();
        while (iter.next()) |item| {
            const range = &item.range;
            const range_start: VAddrSize = @bitCast(range.start);
            const range_end = range_start + range.length;
            if (range_start <= start and range_end <= start) continue;
            if (range_start <= start and range_end >= end) {
                // we are contained in range
                const top_excess_length = start - range_start;
                const bottom_excess_length = range_end - end;
                if (top_excess_length == 0 and bottom_excess_length == 0) {
                    defer self.alloc.destroy(item);
                    defer free_ranges_list.remove(item);
                } else if (top_excess_length > 0 and bottom_excess_length > 0) {
                    range.length = top_excess_length;
                    const end_range = try self.alloc.create(VirtMemRangeListItem);
                    end_range.* = .{
                        .range = .{
                            .start = @bitCast(end),
                            .length = bottom_excess_length,
                            .typ = range.typ,
                        },
                    };
                    free_ranges_list.insertAfter(item, end_range);
                } else if (top_excess_length > 0) {
                    range.length = top_excess_length;
                } else if (bottom_excess_length > 0) {
                    range.start = @bitCast(end);
                    range.length = bottom_excess_length;
                } else {
                    // maybe we forgot a case ?
                    unreachable;
                }
            } else if (range_start <= start) {
                const overlap_length = range_end - start;
                range.length -= overlap_length;
            } else if (range_end >= end) {
                const overlap_length = end - range_start;
                range.start = @bitCast(end);
                range.length -= overlap_length;
                break;
            }
        }
        try self.registerRange(start, length, .{ .typ = dst_typ });
    }

    pub fn allocateRange(self: *VirtualMemoryManager, count: VAddrSize, args: RangeArgs) !VirtMemRange {
        const length = count * arch.constants.default_page_size;
        const typ = args.typ orelse .free;
        const range_list = &self.memory_map[@intFromEnum(typ)];
        var iter = range_list.iter();
        while (iter.next()) |item| {
            var range = &item.range;
            if (range.length == length) {
                range_list.remove(item);
                defer self.alloc.destroy(item);
                return range.*;
            } else if (range.length > length) {
                const new_start: u64 = @as(u64, @bitCast(range.start)) + length;
                range.start = @bitCast(new_start);
                range.length -= length;
                const new_range = VirtMemRange{ .start = range.start, .length = length, .typ = typ };
                return new_range;
            }
        }

        return error.OutOfVirtMemory;
    }
};

pub const PlatformVirtualAllocator = arch.memory.VirtualAllocator(VirtualMemoryManager);
pub const VirtualAllocator = @This();
inner: PlatformVirtualAllocator,

extern const _kernel_end: u64;
extern const fb: u64;

pub fn init(alloc: Allocator) !VirtualAllocator {
    var inner: PlatformVirtualAllocator = .init(alloc, _allocatePages);
    log.info("after init. kernel_end 0x{*}", .{&_kernel_end});

    const quickmap_start = @intFromPtr(&_kernel_end) + 2 * arch.constants.default_page_size;
    const quickmap_length = arch.constants.default_page_size * constants.max_cpu;
    inner.vmm.quickmap.start = @bitCast(quickmap_start);
    inner.vmm.quickmap.length = quickmap_length;

    const stack_start = -%(@as(u64, arch.constants.default_page_size) * constants.max_cpu);
    const quickmap_pt_entry_length = std.mem.alignForward(u64, constants.max_cpu * @sizeOf(PageMapping.Entry), arch.constants.default_page_size);
    const quickmap_pt_entry_start = stack_start - quickmap_pt_entry_length - 2 * arch.constants.default_page_size;
    inner.vmm.quickmap_pt_entry.start = @bitCast(quickmap_pt_entry_start);
    inner.vmm.quickmap_pt_entry.length = quickmap_pt_entry_length;

    log.info("Trying to register ranges", .{});
    // TODO: create a usable page map for the kernel
    // TODO: mark already used vmem pages

    // NOTE: kernel memory map (N = cpu count, padding = 2 pages)
    // -1g               free kernel              (0xffffffffc0000000 => 0xfffffffff0000000)
    // -256m             "mmio" area              (0xfffffffff0000000 => 0xfffffffff8000000)
    // -128m             "fb" framebuffer         (0xfffffffff8000000 => 0xfffffffffc000000)
    // -64m              boot header structure    (0xfffffffffc000000 => 0xfffffffffc001000)
    // -64m+1p           environment string       (0xfffffffffc001000 => 0xfffffffffc002000)
    // -64m+2p           kernel code              (0xfffffffffc002000 => 0xfffffffffc002000 + kernel_size)
    // -64m+2p+ks+2p     quickmap start           (0xfffffffffc002000 + kernel_size + padding => 0xfffffffffc002000 + kernel_size + padding + N * 0x1000)
    //                       .......
    //                   quickmap pte             (stack_end - sizeof(PTE) * N - padding => stack_end - padding)
    //                   stack start (cpuN)       (-N * 0x1000 => -(N-1) * 0x1000)
    //                       ......
    //                   stack start (cpu1)       (0xffffffffffffe000 => 0xfffffffffffff000)
    //    0              stack start (cpu0)       (0xfffffffffffff000 => 0x0000000000000000)
    //
    //  0-4g             ram identity mapped      (0x0000000000000000 => 0x0000000100000000)

    {
        inner.vmm.lock.lock();
        defer inner.vmm.lock.unlock();
        try inner.vmm.registerRange(0xfffffffff0000000, 128 * sizes.mb, .{ .typ = .mmio });
        try inner.vmm.registerRange(@intFromPtr(&fb), 64 * sizes.mb, .{ .typ = .framebuffer });
        const kernel_range_start = 0xfffffffffc000000;
        const kernel_end_addr = @intFromPtr(&_kernel_end);
        const kernel_range_size = kernel_end_addr -% kernel_range_start;
        log.debug("kernel size: {x}", .{kernel_range_size});

        try inner.vmm.registerRange(kernel_range_start, kernel_range_size, .{ .typ = .kernel });
        const stack_size = constants.max_cpu * arch.constants.default_page_size;
        log.debug("stack start: {x} size: {x}", .{ stack_start, stack_size });
        try inner.vmm.registerRange(stack_start, stack_size, .{ .typ = .stack });
        try inner.vmm.registerRange(0x100000, 0x400000 - 0x101000, .{ .typ = .low_kernel });
        try inner.vmm.registerRange(quickmap_pt_entry_start, quickmap_pt_entry_length, .{ .typ = .quickmap_pte });
        try inner.vmm.registerRange(quickmap_start, quickmap_length, .{ .typ = .quickmap });
        const quickmap_end = quickmap_start + quickmap_length;
        try inner.vmm.registerRange(quickmap_end + 2 * arch.constants.default_page_size, quickmap_pt_entry_start - quickmap_end - 4 * arch.constants.default_page_size, .{});
        try inner.vmm.registerRange(0xffffffffc0000000, 0xfffffffff0000000 - 0xffffffffc0000000, .{});
    }
    var self: VirtualAllocator = .{ .inner = inner };

    // unmap nullptr page
    try self.mmap(
        .{ .start = 0, .length = arch.constants.default_page_size, .typ = .used },
        .{ .start = @bitCast(@as(u64, 0)), .length = arch.constants.default_page_size },
        .{ .present = false },
        .{ .force = true },
    );
    return self;
}

pub fn printRanges(self: *const @This()) void {
    for (self.inner.vmm.memory_map, 0..) |range_list, typ_idx| {
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
    try self.inner.vmm.reserveRange(start, length, .free, typ);
}

const VirtualAllocArgs = struct { typ: ?VirtRangeType = null };

pub fn allocateRange(self: *VirtualAllocator, count: u64, args: VirtualAllocArgs) !VirtMemRange {
    return try self.inner.vmm.allocateRange(count, .{ .typ = args.typ });
}

pub fn freeRange(self: *VirtualAllocator, ptr: u64, count: u64, args: VirtualAllocArgs) void {
    _ = self; // autofix
    _ = ptr; // autofix
    _ = count; // autofix
    _ = args; // autofix
    // the only cases we should have here are:
    // - we create a new range
    // - we extend an existing range (change start or length but not both)
    // all other cases should be errors

    // if (args.typ) |typ| {
    //     var iter = self.inner.vmm.reserved_ranges.iter();
    //     while (iter.next()) |item| {
    //         var range = item.range;
    //         if (range.typ != typ) continue;
    //         if (range.length == length) {
    //             self.inner.vmm.reserved_ranges.remove(item);
    //             defer self.inner.vmm.alloc.destroy(item);
    //             return range;
    //         } else if (range.length > length) {
    //             const new_start: u64 = @as(u64, @bitCast(range.start)) + length;
    //             range.start = @bitCast(new_start);
    //             range.length -= length;
    //             const new_range = VirtMemRange{ .start = range.start, .length = length, .typ = typ };
    //             return new_range;
    //         }
    //     }
    // } else {
    //     var iter = self.inner.vmm.free_ranges.iter();
    //     while (iter.next()) |item| {
    //         var range = item.range;
    //         if (range.length == length) {
    //             self.inner.vmm.free_ranges.remove(item);
    //             defer self.inner.vmm.alloc.destroy(item);
    //             return range;
    //         } else if (range.length > length) {
    //             const new_start = @as(u64, @bitCast(range.start)) + length;
    //             range.start = @bitCast(new_start);
    //             range.length -= length;
    //             const new_range = VirtMemRange{ .start = range.start, .length = length };
    //             return new_range;
    //         }
    //     }
    // }

    // return error.OutOfVirtMemory;
}

pub fn quickMap(self: *VirtualAllocator, addr: u64) u64 {
    const quickmap = self.inner.vmm.quickmap.start;
    const quickmap_addr: u64 = @bitCast(quickmap);
    const entry: *PageMapping.Entry = @ptrFromInt(@as(u64, @bitCast(self.inner.vmm.quickmap_pt_entry.start)) + @sizeOf(PageMapping.Entry) * @as(u64, quickmap.pt_idx));
    PlatformVirtualAllocator.writeEntry(entry, addr, DefaultMmapFlags);
    log.info("quickmap {*} 0x{X} -> 0x{X}", .{ entry, quickmap_addr, entry.getAddr() });
    arch.assembly.invalidateVirtualAddress(quickmap_addr);
    return quickmap_addr;
}

pub fn quickUnmap(self: *VirtualAllocator) void {
    const quickmap = self.inner.vmm.quickmap.start;
    const quickmap_addr: u64 = @bitCast(quickmap);
    const entry: *PageMapping.Entry = @ptrFromInt(@as(u64, @bitCast(self.inner.vmm.quickmap_pt_entry.start)) + @sizeOf(PageMapping.Entry) * @as(u64, quickmap.pt_idx));
    PlatformVirtualAllocator.writeEntry(entry, 0, .{});
    log.info("quickmap {*} 0x{X} -> 0x{X}", .{ entry, quickmap_addr, entry.getAddr() });
    arch.assembly.invalidateVirtualAddress(quickmap_addr);
}

const MMapArgs = struct {
    force: bool = false,
};
pub fn mmapPage(self: *VirtualAllocator, paddr: u64, vaddr: u64, flags: MmapFlags, args: MMapArgs) !void {
    if (constants.safety) {
        if (!std.mem.Alignment.fromByteUnits(arch.constants.default_page_size).check(paddr)) return error.BadPhysAddrAlignment;
        if (!std.mem.Alignment.fromByteUnits(arch.constants.default_page_size).check(vaddr)) return error.BadVirtAddrAlignment;
    }

    // log.debug("Mapping paddr {x} to vaddr {x}", .{ paddr, vaddr });
    const entry = try self.getPageTableEntry(@bitCast(vaddr), flags); 
    if (entry.present) {
        if (entry.getAddr() == @as(u64, @bitCast(paddr)) or args.force) {
            log.warn("Overwriting a present entry (old paddr: 0x{X}) with 0x{X}", .{ entry.getAddr(), @as(u64, @bitCast(paddr)) });
        } else {
            @panic("Overwriting existing entry");
        }
    }

    PlatformVirtualAllocator.writeEntry(entry, paddr, flags);
    // log.debug("entry after mapping paddr {x} ({*}): 0x{X}", .{ @as(u64, @bitCast(paddr)), entry, @as(u64, @bitCast(entry.*)) });
}

pub fn mmap(self: *VirtualAllocator, prange: pmem.PhysMemRange, vrange: VirtMemRange, flags: MmapFlags, args: MMapArgs) !void {
    if (constants.safety) {
        if (prange.length != vrange.length) return error.LengthMismatch;
    }

    var physical_addr = prange.start;
    var virtual_addr: u64 = @bitCast(vrange.start);
    const num_pages_to_map = @divExact(prange.length, arch.constants.default_page_size);
    log.debug("Mapping prange {f} to vrange {f} ({d} pages)", .{ prange, vrange, num_pages_to_map });
    for (0..num_pages_to_map) |_| {
        defer physical_addr += arch.constants.default_page_size;
        defer virtual_addr +%= arch.constants.default_page_size;
        self.mmapPage(physical_addr, virtual_addr, flags, args) catch unreachable;
    }
    std.debug.assert(physical_addr == prange.start + prange.length);
}

fn getPageTableEntry(self: *const VirtualAllocator, vaddr: VAddr, flags: MmapFlags) !*PageMapping.Entry {
    return self.inner.getPageTableEntry(vaddr, flags);
}

fn _allocatePages(count: u64) anyerror!pmem.PAddr {
    const prange = try pmem.allocatePages(count, .{});
    return prange.start;
}
