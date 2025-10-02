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
    alloc: Allocator,
    lock: SpinLock,
    free_ranges: VirtMemRangeList,
    reserved_ranges: VirtMemRangeList,
    quickmap_pt_entry: VirtMemRange,
    quickmap: VirtMemRange,

    pub fn init(alloc: Allocator) VirtualMemoryManager {
        const zero: u64 = 0;
        return .{
            .lock = .create(),
            .alloc = alloc,
            .free_ranges = VirtMemRangeList{},
            .reserved_ranges = VirtMemRangeList{},
            .quickmap_pt_entry = .{ .start = @bitCast(zero), .length = 0, .typ = .quickmap_pte },
            .quickmap = .{ .start = @bitCast(zero), .length = 0, .typ = .quickmap },
        };
    }

    pub fn registerRange(self: *VirtualMemoryManager, start: u64, length: u64, args: struct { typ: ?VirtRangeType = null }) !void {
        const end = start +% length;
        // if reserved add range to reserved_ranges otherwise add it to free_ranges
        if (args.typ) |typ| {
            // register a new reserved range of type typ
            log.info("Registering range with type: {s}", .{@tagName(typ)});
            var iter = self.reserved_ranges.iter();
            var current_range: ?*VirtMemRange = null;
            while (iter.next()) |item| {
                const range = &item.range;
                log.info("checking range: {f}", .{range});
                const range_start = @as(u64, @bitCast(range.start));
                const range_end = range_start +% range.length;
                if (typ == range.typ and ((range_start <= start and range_end >= start) or (range_start <= end and range_end >= end))) {
                    current_range = range;
                    log.info("found range to merge into {f}", .{range});
                    break;
                }
            }

            if (current_range) |cr| {
                const current_start = @as(u64, @bitCast(cr.start));
                const current_end = current_start +% cr.length;
                const new_start = @min(current_start, start);
                const new_end = @max(current_end, end);
                cr.start = @bitCast(new_start);
                cr.length = new_end - new_start;
            } else {
                const reserved_range_item = try self.alloc.create(VirtMemRangeListItem);
                reserved_range_item.* = .{
                    .range = .{
                        .start = @bitCast(start),
                        .length = length,
                        .typ = typ,
                    },
                };
                log.debug("allocated new range {f}", .{reserved_range_item.range});
                self.reserved_ranges.append(reserved_range_item);
            }
        } else {
            log.info("Registering free range 0x{X} -> 0x{X}", .{ start, end });
            var iter = self.free_ranges.iter();
            var current_range: ?*VirtMemRange = null;
            while (iter.next()) |item| {
                const range = &item.range;
                log.info("checking range: {any}", .{range});
                const range_start = @as(u64, @bitCast(range.start));
                const range_end = range_start +% range.length;
                if ((range_start <= start and range_end >= start) or (range_start <= end and range_end >= end)) {
                    current_range = range;
                    break;
                }
            }

            log.info("Current range: {any}", .{current_range});

            if (current_range) |cr| {
                const current_start = @as(u64, @bitCast(cr.start));
                const current_end = current_start +% cr.length;
                const new_start = @min(current_start, start);
                const new_end = @max(current_end, end);
                cr.start = @bitCast(new_start);
                cr.length = new_end - new_start;
            } else {
                log.debug("No current range", .{});
                const free_range_item = try self.alloc.create(VirtMemRangeListItem);
                free_range_item.* = .{
                    .range = .{
                        .start = @bitCast(start),
                        .length = length,
                    },
                };
                self.free_ranges.append(free_range_item);
            }
        }
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
        try inner.vmm.registerRange(0x1000, 0x400000 - 0x1000, .{ .typ = .low_kernel });
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
    var iter = self.inner.vmm.free_ranges.iter();
    log.debug("Free virtual ranges", .{});
    while (iter.next()) |list_item| {
        log.debug("{f}", .{list_item});
    }

    iter = self.inner.vmm.reserved_ranges.iter();
    log.debug("Reserved virtual ranges", .{});
    while (iter.next()) |list_item| {
        log.debug("{f}", .{list_item});
    }
}

pub fn reserveRange(self: *VirtualAllocator, start: u64, length: u64, typ: VirtRangeType) !void {
    // reserved a free range (moves the range from free_ranges to reserved_ranges)
    const end = start + length;
    var iter = self.inner.vmm.free_ranges.iter();
    while (iter.next()) |item| {
        const range = &item.range;
        const range_start = @as(u64, @bitCast(range.start));
        const range_end = range_start + range.length;
        if ((range_start <= start and range_end >= start) or (range_start <= end and range_end >= end)) {
            const start_diff = range_start - start;
            const end_diff = range_end - end;

            if (start_diff <= 0 and end_diff >= 0) {
                // resize the existing range to [S1 S2]
                range.length = start - range_start;
                // create a new range for [E2 E1]
                const free_range_item = try self.inner.vmm.alloc.create(VirtMemRangeListItem);
                free_range_item.* = .{ .range = .{ .start = @bitCast(end), .length = range_end - end } };
                self.inner.vmm.free_ranges.insertAfter(item, free_range_item);
            } else if (start_diff <= 0) {
                range.length -= range_end - start;
            } else if (start_diff > 0) {
                range.start += start_diff;
                range.length -= start_diff;
            }
            break;
        }
    }
    // or create a new reserved range if it doesn't exist already
    const reserved_range_item = try self.inner.vmm.alloc.create(VirtMemRangeListItem);
    reserved_range_item.* = .{
        .range = .{
            .start = @bitCast(start),
            .length = length,
            .typ = typ,
        },
    };
    self.inner.vmm.reserved_ranges.append(reserved_range_item);
}

pub fn allocateRange(self: *VirtualAllocator, count: u64, args: struct { typ: ?VirtRangeType = null }) !VirtMemRange {
    const length = count * arch.constants.default_page_size;
    if (args.typ) |typ| {
        var iter = self.inner.vmm.reserved_ranges.iter();
        while (iter.next()) |item| {
            var range = item.range;
            if (range.typ != typ) continue;
            if (range.length == length) {
                self.inner.vmm.reserved_ranges.remove(item);
                defer self.inner.vmm.alloc.destroy(item);
                return range;
            } else if (range.length > length) {
                const new_start: u64 = @as(u64, @bitCast(range.start)) + length;
                range.start = @bitCast(new_start);
                range.length -= length;
                const new_range = VirtMemRange{ .start = range.start, .length = length, .typ = typ };
                return new_range;
            }
        }
    } else {
        var iter = self.inner.vmm.free_ranges.iter();
        while (iter.next()) |item| {
            var range = item.range;
            if (range.length == length) {
                self.inner.vmm.free_ranges.remove(item);
                defer self.inner.vmm.alloc.destroy(item);
                return range;
            } else if (range.length > length) {
                const new_start = @as(u64, @bitCast(range.start)) + length;
                range.start = @bitCast(new_start);
                range.length -= length;
                const new_range = VirtMemRange{ .start = range.start, .length = length };
                return new_range;
            }
        }
    }

    return error.OutOfVirtMemory;
}

pub fn freeRange(self: *VirtualAllocator, range: *VirtMemRange) void {
    _ = self; // autofix
    _ = range; // autofix
    // WARN: we take a ptr to range but we can't be sure the owner has finished with it. can cause access issues.
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
    const entry = self.getPageTableEntry(@bitCast(vaddr), flags) catch unreachable;
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
        if (idx % 100 == 0) {
            log.debug("Mapping paddr {x} to vaddr {x}", .{ physical_addr, virtual_addr });
        }
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
