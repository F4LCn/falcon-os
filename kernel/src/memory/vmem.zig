const std = @import("std");
const constants = @import("constants");
const SpinLock = @import("../synchronization.zig").SpinLock;
const DoublyLinkedList = @import("../list.zig").DoublyLinkedList;
const Registers = @import("../registers.zig");
const Allocator = std.mem.Allocator;

// TODO: make this great again
const pmem = @import("pmem.zig");

const log = std.log.scoped(.vmem);

const ReadWrite = enum(u1) {
    read_execute = 0,
    read_write = 1,
};
const UserSupervisor = enum(u1) {
    supervisor = 0,
    user = 1,
};
const PageSize = enum(u1) {
    normal = 0,
    large = 1,
};

const MmapFlags = packed struct(u64) {
    present: bool = false,
    read_write: ReadWrite = .read_write,
    user_supervisor: UserSupervisor = .supervisor,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    page_size: PageSize = .normal,
    global: bool = false,
    _pad: u54 = 0,
    execution_disable: bool = false,
};

pub const DefaultMmapFlags: MmapFlags = .{
    .present = true,
    .read_write = .read_write,
};
const PageMapping = extern struct {
    const Entry = packed struct(u64) {
        present: bool = false,
        read_write: ReadWrite = .read_write,
        user_supervisor: UserSupervisor = .supervisor,
        write_through: bool = false,
        cache_disable: bool = false,
        accessed: bool = false,
        dirty: bool = false,
        page_size: PageSize = .normal,
        global: bool = false,
        _pad0: u3 = 0,
        addr: u36 = 0,
        _pad1: u15 = 0,
        execution_disable: bool = false,

        pub fn getAddr(self: *const Entry) u64 {
            return @as(u64, @intCast(self.addr)) << 12;
        }

        pub fn print(self: *const Entry) void {
            log.debug("entry: {*}", .{self});
            log.info("Addr: 0x{X} - 0x{X}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
        }
    };
    mappings: [@divExact(constants.arch_page_size, @sizeOf(Entry))]Entry,

    pub fn print(self: *const PageMapping, lvl: u8, vaddr: *VAddr) void {
        for (&self.mappings, 0..) |*mapping, idx| {
            if (!mapping.present) continue;
            switch (lvl) {
                4 => vaddr.pml4_idx = @intCast(idx),
                3 => vaddr.pdp_idx = @intCast(idx),
                2 => vaddr.pd_idx = @intCast(idx),
                1 => {
                    vaddr.pt_idx = @intCast(idx);
                    log.info("VAddr: 0x{X}: {any}", .{ @as(u64, @bitCast(vaddr.*)), vaddr });
                    mapping.print();
                    continue;
                },
                else => unreachable,
            }
            // log.debug("vaddr: {any}", .{vaddr});
            log.debug("mapping: {*}", .{mapping});
            const next_level_mapping: *PageMapping = @ptrFromInt(mapping.getAddr());
            next_level_mapping.print(lvl - 1, vaddr);
        }
    }
};

const VirtRangeType = enum(u8) {
    quickmap,
    quickmap_pte,
    framebuffer,
};

const VAddr = packed struct(u64) {
    offset: u12 = 0,
    pt_idx: u9 = 0,
    pd_idx: u9 = 0,
    pdp_idx: u9 = 0,
    pml4_idx: u9 = 0,
    _pad: u16 = 0,
};
const VirtMemRange = struct {
    // vm: *VMEM,
    start: VAddr,
    length: u64,
    type: ?VirtRangeType = null,
    // mapped: bool = false,

    pub fn format(
        self: *const @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const start_addr = @as(u64, @bitCast(self.start));
        if (self.type) |typ| {
            try writer.print("{*}[0x{X} -> 0x{X} (sz={X}) {s}]", .{ self, start_addr, start_addr + self.length, self.length, @tagName(typ) });
        } else {
            try writer.print("{*}[0x{X} -> 0x{X} (sz={X}) free]", .{ self, start_addr, start_addr + self.length, self.length });
        }
    }

    // pub fn map(self: *@This(), prange: pmem.PhysMemRange) !void {
    //     if (self.length < prange.length) return error.TooSmall;
    //     self.vm.mmap(prange.start, self.start, DefaultMmapFlags);
    //     self.mapped = true;
    // }

    // pub fn unmap(self: *@This()) !void {
    //     if (!self.mapped) {
    //         return error.NotMapped;
    //     }
    //     self.vm.mmap(0x0, self.start, .{ .present = false });
    // }
};
const VirtMemRangeListItem = struct {
    const Self = @This();
    range: VirtMemRange,
    prev: ?*Self = null,
    next: ?*Self = null,

    pub fn format(
        self: *const @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{*}[range={any}, p=0x{X}, n=0x{X}]", .{ self, &self.range, @intFromPtr(self.prev), @intFromPtr(self.next) });
    }
};
const VirtMemRangeList = DoublyLinkedList(VirtMemRangeListItem, .prev, .next);
const VirtualMemoryManager = struct {
    const Self = @This();
    alloc: Allocator,
    lock: SpinLock,
    free_ranges: VirtMemRangeList,
    reserved_ranges: VirtMemRangeList,
    quickmap_pt_entry: VirtMemRange,
    quickmap: VirtMemRange,

    pub fn init(alloc: Allocator) Self {
        const zero: u64 = 0;
        return .{
            .lock = .create(),
            .alloc = alloc,
            .free_ranges = VirtMemRangeList{},
            .reserved_ranges = VirtMemRangeList{},
            .quickmap_pt_entry = .{ .start = @bitCast(zero), .length = 0, .type = .quickmap_pte },
            .quickmap = .{ .start = @bitCast(zero), .length = 0, .type = .quickmap },
        };
    }

    pub fn registerRange(self: *Self, start: u64, length: u64, args: struct { typ: ?VirtRangeType = null }) !void {
        const end = start + length;
        // if reserved add range to reserved_ranges otherwise add it to free_ranges
        if (args.typ) |typ| {
            // register a new reserved range of type typ
            log.info("Registering range with type: {s}", .{@tagName(typ)});
            var iter = self.reserved_ranges.iter();
            var current_range: ?*VirtMemRange = null;
            while (iter.next()) |item| {
                const range = &item.range;
                log.info("checking range: {any}", .{range});
                const range_start = @as(u64, @bitCast(range.start));
                const range_end = range_start + range.length;
                if (typ == range.type and ((range_start <= start and range_end >= start) or (range_start <= end and range_end >= end))) {
                    current_range = range;
                    break;
                }
            }

            if (current_range) |cr| {
                const current_start = @as(u64, @bitCast(cr.start));
                const current_end = current_start + cr.length;
                const new_start = @min(current_start, start);
                const new_end = @max(current_end, end);
                cr.start = @bitCast(new_start);
                cr.length = new_end - new_start;
            } else {
                log.debug("No current range", .{});
                const reserved_range_item = try self.alloc.create(VirtMemRangeListItem);
                reserved_range_item.* = .{ .range = .{ .start = @bitCast(start), .length = length, .type = typ } };
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
                const range_end = range_start + range.length;
                if ((range_start <= start and range_end >= start) or (range_start <= end and range_end >= end)) {
                    current_range = range;
                    break;
                }
            }

            log.info("Current range: {any}", .{current_range});

            if (current_range) |cr| {
                const current_start = @as(u64, @bitCast(cr.start));
                const current_end = current_start + cr.length;
                const new_start = @min(current_start, start);
                const new_end = @max(current_end, end);
                cr.start = @bitCast(new_start);
                cr.length = new_end - new_start;
            } else {
                log.debug("No current range", .{});
                const free_range_item = try self.alloc.create(VirtMemRangeListItem);
                free_range_item.* = .{ .range = .{ .start = @bitCast(start), .length = length } };
                self.free_ranges.append(free_range_item);
            }
        }
    }
};

root: u64,
levels: u8,
vmm: VirtualMemoryManager,

const VMEM = @This();

extern const _kernel_end: u64;

pub fn init(alloc: Allocator) !@This() {
    const root = Registers.readCR(.cr3);
    log.info("Got current pagemap: 0x{X}", .{root});
    var vmm = VirtualMemoryManager.init(alloc);
    log.info("after init. kernel_end 0x{X}", .{&_kernel_end});

    const quickmap_start = @intFromPtr(&_kernel_end) + 2 * constants.arch_page_size;
    const quickmap_length = constants.arch_page_size * constants.max_cpu;
    vmm.quickmap.start = @bitCast(quickmap_start);
    vmm.quickmap.length = quickmap_length;

    const quickmap_pt_entry_length = std.mem.alignForward(u64, constants.max_cpu * @sizeOf(PageMapping.Entry), constants.arch_page_size);
    const quickmap_pt_entry_start = -%(@as(u64, constants.arch_page_size) * constants.max_cpu) - quickmap_pt_entry_length - 2 * constants.arch_page_size;
    vmm.quickmap_pt_entry.start = @bitCast(quickmap_pt_entry_start);
    vmm.quickmap_pt_entry.length = quickmap_pt_entry_length;

    log.info("Try to reg ranges", .{});
    try vmm.registerRange(quickmap_start, quickmap_length, .{ .typ = .quickmap });
    try vmm.registerRange(quickmap_pt_entry_start, quickmap_pt_entry_length, .{ .typ = .quickmap_pte });
    try vmm.registerRange(0x1000, 0x9000, .{});
    try vmm.registerRange(0x3000, 0x5000, .{});
    try vmm.registerRange(0x9000, 0x19000, .{});
    try vmm.registerRange(0xB0000, 0x10000, .{});
    try vmm.registerRange(0x22000, 0xB0000 - 0x22000, .{});
    try vmm.registerRange(0xffffffffc0000000, 64 * 1024 * 1024, .{ .typ = .framebuffer });

    return .{
        .root = root,
        .levels = 4,
        .vmm = vmm,
    };
}

pub fn printFreeRanges(self: *const @This()) void {
    var iter = self.vmm.free_ranges.iter();
    log.debug("Free virtual ranges", .{});
    while (iter.next()) |list_item| {
        log.debug("{any}", .{list_item});
    }
}

pub fn printReservedRanges(self: *const @This()) void {
    var iter = self.vmm.reserved_ranges.iter();
    log.debug("Reserved virtual ranges", .{});
    while (iter.next()) |list_item| {
        log.debug("{any}", .{list_item});
    }
}

fn invalidateTLB(addr: u64) void {
    // call instruction to invalidate the tbl cache for addr
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
        : "memory"
    );
}

pub fn reserveRange(self: *@This(), start: u64, length: u64, typ: VirtRangeType) !void {
    // reserved a free range (moves the range from free_ranges to reserved_ranges)
    const end = start + length;
    var iter = self.vmm.free_ranges.iter();
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
                const free_range_item = try self.alloc.create(VirtMemRangeListItem);
                free_range_item.* = .{ .range = .{ .start = @bitCast(end), .length = range_end - end } };
                self.vmm.free_ranges.insertAfter(item, free_range_item);
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
    const reserved_range_item = try self.alloc.create(VirtMemRangeListItem);
    reserved_range_item.* = .{ .range = .{ .start = @bitCast(start), .length = length, .type = typ } };
    self.reserved_ranges.append(reserved_range_item);
}

pub fn allocateRange(self: *@This(), length: u64, args: struct { typ: ?VirtRangeType = null }) VirtMemRange {
    // allocate a range either from free_ranges (typ is null) or reserved_ranges
    if (args.typ) |typ| {
        var iter = self.vmm.reserved_ranges.iter();
        while (iter.next()) |item| {
            var range = item.range;
            if (range.type != typ) continue;
            if (range.length == length) {
                self.vmm.reserved_ranges.remove(item);
                defer self.vmm.alloc.destroy(item);
                return range;
            } else if (range.length > length) {
                const new_start: u64 = @as(u64, @bitCast(range.start)) + length;
                range.start = @bitCast(new_start);
                range.length -= length;
                const new_range = VirtMemRange{ .start = range.start, .length = length, .type = typ };
                return new_range;
            }
        }
    } else {
        var iter = self.vmm.free_ranges.iter();
        while (iter.next()) |item| {
            var range = item.range;
            if (range.length == length) {
                self.vmm.free_ranges.remove(item);
                defer self.vmm.alloc.destroy(item);
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

    unreachable;
}

pub fn freeRange(self: *@This(), range: *VirtMemRange) void {
    _ = self; // autofix
    _ = range; // autofix
    // WARN: we take a ptr to range but we can't be sure the owner has finished with it. can cause access issues.
}

pub fn quickMap(self: *@This(), addr: u64) u64 {
    const quickmap = self.vmm.quickmap.start;
    const quickmap_addr: u64 = @bitCast(quickmap);
    const entry: *PageMapping.Entry = @ptrFromInt(@as(u64, @bitCast(self.vmm.quickmap_pt_entry.start)) + @sizeOf(PageMapping.Entry) * @as(u64, quickmap.pt_idx));
    writeEntry(entry, addr, DefaultMmapFlags);
    log.info("quickmap {*} 0x{X} -> 0x{X}", .{ entry, quickmap_addr, entry.getAddr() });
    invalidateTLB(quickmap_addr);
    return quickmap_addr;
}

pub fn quickUnmap(self: *@This()) void {
    const quickmap = self.vmm.quickmap.start;
    const quickmap_addr: u64 = @bitCast(quickmap);
    const entry: *PageMapping.Entry = @ptrFromInt(@as(u64, @bitCast(self.vmm.quickmap_pt_entry.start)) + @sizeOf(PageMapping.Entry) * @as(u64, quickmap.pt_idx));
    writeEntry(entry, 0, .{});
    log.info("quickmap {*} 0x{X} -> 0x{X}", .{ entry, quickmap_addr, entry.getAddr() });
    invalidateTLB(quickmap_addr);
}

pub fn mmap(self: *@This(), prange: pmem.PhysMemRange, vrange: VirtMemRange, flags: MmapFlags) !void {
    if (prange.length > vrange.length) return error.TooSmall;

    const physical_addr = std.mem.alignBackward(u64, prange.start, constants.arch_page_size);
    const virtual_addr = vrange.start;

    const entry = try self.getPageTableEntry(virtual_addr, flags);
    if (entry.present) {
        log.warn("Overwriting a present entry (old paddr: 0x{X}) with 0x{X}", .{ entry.getAddr(), @as(u64, @bitCast(physical_addr)) });
    }

    writeEntry(entry, physical_addr, flags);
    log.debug("entry after mapping({*}): 0x{X}", .{ entry, @as(u64, @bitCast(entry.*)) });
}

fn getPageTableEntry(self: *const @This(), vaddr: VAddr, flags: MmapFlags) !*PageMapping.Entry {
    const pml4_mapping: *PageMapping = @ptrFromInt(self.root);
    log.debug("PML4: {*}", .{pml4_mapping});
    const pdp_mapping = try getOrCreateMapping(pml4_mapping, vaddr.pml4_idx);
    log.debug("PDP: {*}", .{pdp_mapping});
    const pd_mapping = try getOrCreateMapping(pdp_mapping, vaddr.pdp_idx);
    log.debug("PD: {*}", .{pd_mapping});
    const pt_mapping = try getOrCreateMapping(pd_mapping, vaddr.pd_idx);
    log.debug("PT: {*}", .{pt_mapping});
    if (flags.page_size == .large) {
        // TODO: handle large pages here
        @panic("large pages unhandled");
    }
    const entry = &pt_mapping.mappings[vaddr.pt_idx];
    return entry;
}

fn getOrCreateMapping(mapping: *PageMapping, idx: u9) !*PageMapping {
    const next_level: *PageMapping.Entry = &mapping.mappings[idx];
    if (!next_level.present) {
        const maybe_page = pmem.allocatePage(1, .{});
        if (maybe_page) |page_ptr| {
            writeEntry(next_level, page_ptr.start, .{ .present = true, .read_write = .read_write });
            return @ptrFromInt(page_ptr.start);
        } else {
            return error.PhysicalAllocationError;
        }
    }
    const addr = next_level.getAddr();
    return @ptrFromInt(addr);
}

fn writeEntry(entry: *PageMapping.Entry, paddr: u64, flags: MmapFlags) void {
    entry.* = @bitCast(paddr | @as(u64, @bitCast(flags)));
}
