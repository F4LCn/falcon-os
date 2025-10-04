const std = @import("std");
const log = std.log.scoped(.@"x86_64.memory");
const constants = @import("constants.zig");
const registers = @import("registers.zig");

pub const PAddrSize = u64;
pub const PAddr = u64;

pub const VAddrSize = u64;
pub const VAddr = packed struct(u64) {
    offset: u12 = 0,
    pt_idx: u9 = 0,
    pd_idx: u9 = 0,
    pdp_idx: u9 = 0,
    pml4_idx: u9 = 0,
    _pad: u16 = 0,
};
pub const ReadWrite = enum(u1) {
    read_execute = 0,
    read_write = 1,
};
pub const UserSupervisor = enum(u1) {
    supervisor = 0,
    user = 1,
};
pub const PageSize = enum(u1) {
    normal = 0,
    large = 1,
};
pub const MmapFlags = packed struct(u64) {
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
pub const PageMapping = extern struct {
    pub const Entry = packed struct(u64) {
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

        pub fn getAddr(self: *const Entry) PAddr {
            return @as(PAddrSize, @intCast(self.addr)) << 12;
        }

        pub fn print(self: *const Entry) void {
            log.debug("entry: {*}", .{self});
            log.info("Addr: 0x{X} - 0x{X}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
        }
    };
    mappings: [@divExact(constants.default_page_size, @sizeOf(Entry))]Entry,

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

pub fn VirtualAllocator(comptime VirtualMemoryManagerType: type) type {
    return struct {
        const Self = @This();
        root: u64,
        levels: u8,
        vmm: VirtualMemoryManagerType,

        // FIXME: makeshift page allocator
        allocate_pages: *const fn (count: u64) anyerror!PAddr,

        pub fn init(alloc: std.mem.Allocator, allocate_pages: *const fn (count: PAddrSize) anyerror!PAddr) Self {
            const root = registers.readCR(.cr3);
            log.info("Got current pagemap: 0x{X}", .{root});
            const vmm = VirtualMemoryManagerType.init(alloc);
            return .{
                .root = root,
                .vmm = vmm,
                .levels = 4,
                .allocate_pages = allocate_pages,
            };
        }

        pub fn getPageTableEntry(self: *const Self, vaddr: VAddr, flags: MmapFlags, args: struct { create_if_missing: bool = true }) !*PageMapping.Entry {
            const pml4_mapping: *PageMapping = @ptrFromInt(self.root);
            // log.debug("PML4: {*}", .{pml4_mapping});
            const pdp_mapping = try self.getOrCreateMapping(pml4_mapping, vaddr.pml4_idx, args.create_if_missing);
            // log.debug("PDP: {*}", .{pdp_mapping});
            const pd_mapping = try self.getOrCreateMapping(pdp_mapping, vaddr.pdp_idx, args.create_if_missing);
            // log.debug("PD: {*}", .{pd_mapping});
            const pt_mapping = try self.getOrCreateMapping(pd_mapping, vaddr.pd_idx, args.create_if_missing);
            // log.debug("PT: {*}", .{pt_mapping});
            if (flags.page_size == .large) {
                // TODO: handle large pages here
                @panic("large pages unhandled");
            }
            const entry = &pt_mapping.mappings[vaddr.pt_idx];
            return entry;
        }

        fn getOrCreateMapping(self: Self, mapping: *PageMapping, idx: u9, create_if_missing: bool) !*PageMapping {
            const next_level: *PageMapping.Entry = &mapping.mappings[idx];
            if (!next_level.present) {
                if (!create_if_missing) return error.MissingPageMapping;
                const page_ptr = try self.allocate_pages(1);
                writeEntry(next_level, page_ptr, .{ .present = true, .read_write = .read_write });
                return @ptrFromInt(page_ptr);
            }
            const addr = next_level.getAddr();
            return @ptrFromInt(addr);
        }

        pub fn writeEntry(entry: *PageMapping.Entry, paddr: PAddr, flags: MmapFlags) void {
            entry.* = @bitCast(paddr | @as(u64, @bitCast(flags)));
        }
    };
}
