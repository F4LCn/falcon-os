const std = @import("std");
const BootloaderError = @import("errors.zig").BootloaderError;
const Globals = @import("globals.zig");
const Constants = @import("constants.zig");

const log = std.log.scoped(.vmm);

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
    mappings: [@divExact(Constants.ARCH_PAGE_SIZE, @sizeOf(Entry))]Entry,

    pub fn print(self: *const PageMapping, lvl: u8, vaddr: *Pml4VirtualAddress) void {
        for (&self.mappings, 0..) |*mapping, idx| {
            if (!mapping.present) continue;
            switch (lvl) {
                4 => vaddr.pml4_idx = @intCast(idx),
                3 => vaddr.pdp_idx = @intCast(idx),
                2 => vaddr.pd_idx = @intCast(idx),
                1 => {
                    vaddr.pt_idx = @intCast(idx);
                    log.info("VAddr: 0x{X}: {any}", .{@as(u64, @bitCast(vaddr.*)), vaddr});
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

const Pml4VirtualAddress = packed struct(u64) {
    offset: u12 = 0,
    pt_idx: u9 = 0,
    pd_idx: u9 = 0,
    pdp_idx: u9 = 0,
    pml4_idx: u9 = 0,
    _pad: u16 = 0,
};

pub const Address = union(enum) {
    paddr: u64,
    vaddr: Pml4VirtualAddress,
};

root: u64,
levels: u8 = 4,

const Self = @This();

fn allocatePages(num_pages: u64) BootloaderError![*]align(Constants.ARCH_PAGE_SIZE) u8 {
    var page_ptr: [*]align(Constants.ARCH_PAGE_SIZE) u8 = undefined;
    const status = Globals.boot_services.allocatePages(.AllocateAnyPages, .LoaderData, num_pages, &page_ptr);
    switch (status) {
        .Success => log.debug("Allocated {d} pages for address space", .{num_pages}),
        else => return BootloaderError.AddressSpaceAllocatePages,
    }
    @memset(page_ptr[0 .. num_pages * Constants.ARCH_PAGE_SIZE], 0);
    return page_ptr;
}

pub fn create() BootloaderError!Self {
    const root_ptr = try allocatePages(1);
    return .{
        .root = @intFromPtr(root_ptr),
    };
}

pub fn mmap(self: *const Self, vaddr: Address, paddr: Address, flags: MmapFlags) BootloaderError!void {
    const physical_addr = switch (paddr) {
        .paddr => |x| std.mem.alignBackward(u64, x, Constants.ARCH_PAGE_SIZE),
        else => return BootloaderError.BadAddressType,
    };
    const virtual_addr = switch (vaddr) {
        .vaddr => |x| x,
        else => return BootloaderError.BadAddressType,
    };

    const pml4_mapping: *PageMapping = @ptrFromInt(self.root);
    log.debug("PML4: {*}", .{pml4_mapping});
    const pdp_mapping = try getOrCreateMapping(pml4_mapping, virtual_addr.pml4_idx);
    log.debug("PDP: {*}", .{pdp_mapping});
    const pd_mapping = try getOrCreateMapping(pdp_mapping, virtual_addr.pdp_idx);
    log.debug("PD: {*}", .{pd_mapping});
    const pt_mapping = try getOrCreateMapping(pd_mapping, virtual_addr.pd_idx);
    log.debug("PT: {*}", .{pt_mapping});
    if (flags.page_size == .large) {
        // TODO: handle large pages here
        @panic("large pages unhandled");
    }
    const entry = &pt_mapping.mappings[virtual_addr.pt_idx];

    writeEntry(entry, physical_addr, flags);
    log.debug("entry after mapping({*}): 0x{X}", .{ entry, @as(u64, @bitCast(entry.*)) });
}

fn getOrCreateMapping(mapping: *PageMapping, idx: u9) BootloaderError!*PageMapping {
    const next_level: *PageMapping.Entry = &mapping.mappings[idx];
    if (!next_level.present) {
        const page_ptr = try allocatePages(1);
        writeEntry(next_level, @intFromPtr(page_ptr), .{ .present = true, .read_write = .read_write });
        return @ptrCast(page_ptr);
    }
    const addr = next_level.getAddr();
    return @ptrFromInt(addr);
}

fn writeEntry(entry: *PageMapping.Entry, paddr: u64, flags: MmapFlags) void {
    entry.* = @bitCast(paddr | @as(u64, @bitCast(flags)));
}

pub fn print(self: *const Self) void {
    const pml4_mapping: *PageMapping = @ptrFromInt(self.root);
    var vaddr: Pml4VirtualAddress = .{};
    pml4_mapping.print(self.levels, &vaddr);
}

test "write entry" {
    const entry = PageMapping.Entry{ .addr = 0xC00CAFEB, .present = true };
    try std.testing.expectEqual(@as(u64, @bitCast(entry)), 0xC00CAFEB003);
}

test "get addr from entry" {
    const entry = PageMapping.Entry{ .addr = 0xC00CAFEB, .present = true };
    try std.testing.expectEqual(entry.getAddr(), 0xC00CAFEB000);
}

test "get present mapping" {
    var page_map = PageMapping{ .mappings = [_]PageMapping.Entry{.{}} ** 512 };
    page_map.mappings[10] = PageMapping.Entry{ .addr = 0xC00CAFEB, .present = true };
    const result = try getOrCreateMapping(&page_map, 10);
    try std.testing.expectEqual(@as(u64, @intFromPtr(result)), 0xC00CAFEB000);
}
