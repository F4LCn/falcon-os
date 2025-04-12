const std = @import("std");
const SpinLock = @import("../synchronization.zig").SpinLock;
const DoublyLinkedList = @import("../list.zig").DoublyLinkedList;
const Constants = @import("../constants.zig");

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
    mappings: [@divExact(Constants.arch_page_size, @sizeOf(Entry))]Entry,

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

const VirtRangeType = enum(u8) { _ };

const VAddr = packed struct(u64) {};
const VirtMemRange = struct {
    start: VAddr,
    length: u64,
    type: ?VirtRangeType = null,

    pub fn format(
        self: *const @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{*}[0x{X} -> 0x{X} (sz={X}) {any}]", .{ self, self.start, self.start + self.length, self.length, self.type });
    }
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
    lock: SpinLock,
    free_ranges: VirtMemRangeList,
    reserved_ranges: VirtMemRangeList,
    quickmap_pt_entry: VirtMemRange,
    quickmap: VirtMemRange,

    pub fn init() Self {
        return .{
            .lock = .create(),
            .free_ranges = VirtMemRangeList{},
            .reserved_ranges = VirtMemRangeList{},
            .quickmap_pt_entry = .{ .start = @bitCast(0), .length = 0, .typ = .quickmap_pte },
            .quickmap = .{ .start = @bitCast(0), .length = 0, .typ = .quickmap },
        };
    }

    pub fn registerRange(self: *Self, start: u64, length: u64, args: struct { typ: ?VirtRangeType = null }) !void {
        _ = self;
        _ = start;
        _ = length;
        _ = args;
        // if reserved add range to reserved_ranges otherwise add it to free_ranges
    }
};

root: u64,
levels: u8,
vmm: VirtualMemoryManager,

extern const _kernel_end: u64;

pub fn init() @This() {
    // TODO: read current page map addr (CR3)
    const root = 0x1234;
    const vmm = .{};

    const quickmap_start = _kernel_end + 2 * Constants.arch_page_size;
    const quickmap_length = Constants.arch_page_size * Constants.max_cpu;

    const quickmap_pt_entry_length = std.mem.alignForward(u64, Constants.max_cpu * @sizeOf(PageMapping.Entry), Constants.arch_page_size);
    const quickmap_pt_entry_start = -%@as(u64, Constants.arch_page_size) * Constants.max_cpu - quickmap_pt_entry_length - 2 * Constants.arch_page_size;

    vmm.registerRange(quickmap_start, quickmap_length, .{ .typ = .quickmap });
    vmm.registerRange(quickmap_pt_entry_start, quickmap_pt_entry_length, .{ .typ = .quickmap_pte });

    return .{
        .root = root,
        .levels = 4,
        .vmm = vmm,
    };
}

fn invalidate_tlb(addr: u64) void {
    _ = addr; // autofix
    // call instruction to invalidate the tbl cache for addr
}

pub fn reserveRange(self: *@This(), start: u64, length: u64, typ: VirtRangeType) !void {
    _ = self; // autofix
    _ = typ; // autofix
    _ = start; // autofix
    _ = length; // autofix
    // reserved a free range (moves the range from free_ranges to reserved_ranges)
    // or create a new reserved range if it doesn't exist already
}

pub fn allocateRange(self: *@This(), length: u64, args: struct { typ: ?VirtRangeType = null }) VirtMemRange {
    _ = self; // autofix
    _ = length; // autofix
    _ = args; // autofix
    // allocate a range either from free_ranges (typ is null) or reserved_ranges
}

pub fn freeRange(self: *@This(), range: *VirtMemRange) void {
    _ = self; // autofix
    _ = range; // autofix
    // WARN: we take a ptr to range but we can't be sure the owner has finished with it. can cause access issues.
}

pub fn quickMap(self: *@This(), addr: u64) u64 {
    const entry: *PageMapping.Entry = @ptrFromInt(self.quickmap_pt_entry.start);
    writeEntry(entry, addr, DefaultMmapFlags);
    const quickmap_addr = ??;
    invalidate_tlb(quickmap_addr);
    return quickmap_addr;
}

pub fn quickUnmap(self: *@This(), addr: u64) void {
    _ = addr; // autofix

    const entry: *PageMapping.Entry = @ptrFromInt(self.quickmap_pt_entry.start);
    writeEntry(entry, 0, .{});
    invalidate_tlb(quickmap_addr);
}

fn writeEntry(entry: *PageMapping.Entry, paddr: u64, flags: MmapFlags) void {
    entry.* = @bitCast(paddr | @as(u64, @bitCast(flags)));
}
