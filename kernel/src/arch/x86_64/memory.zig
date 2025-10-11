const std = @import("std");
const log = std.log.scoped(.@"x86_64.memory");
const constants = @import("constants.zig");
const options = @import("options");
const registers = @import("registers.zig");
const flcn = @import("flcn");
const assembly = @import("assembly.zig");

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

    pub fn toAddr(self: VAddr) VAddrSize {
        return @bitCast(self);
    }
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

var env = @extern([*]u8, .{ .name = "env", .visibility = .hidden });
pub const VirtualMemoryManager = flcn.vmm.VirtualMemoryManager(VAddr, VAddrSize, constants.default_page_size);
pub const VirtMemRange = VirtualMemoryManager.VirtMemRange;
pub const MMapArgs = struct {
    force: bool = false,
};
pub const PageMapManager = struct {
    const Self = @This();
    root: u64,
    levels: u8,
    page_offset: VAddrSize,

    // FIXME: makeshift page allocator
    allocate_pages: *const fn (count: u64) anyerror!PAddr,

    pub fn init(allocate_pages: *const fn (count: PAddrSize) anyerror!PAddr) !Self {
        log.info("reading kernel config", .{});
        const page_offset = try readPageOffset();
        const root = registers.readCR(.cr3);
        log.info("Got current pagemap: 0x{X}", .{root});
        return .{
            .root = root,
            .levels = 4,
            .page_offset = page_offset,
            .allocate_pages = allocate_pages,
        };
    }

    fn readPageOffset() !VAddrSize {
        log.info("env: {*}", .{env});
        const config = env[0..constants.default_page_size];
        var line_tokenizer = std.mem.tokenizeScalar(u8, config, '\n');
        while (line_tokenizer.next()) |line| {
            var kv_split_iterator = std.mem.splitScalar(u8, line, '=');
            if (kv_split_iterator.next()) |key| {
                const value = kv_split_iterator.rest();
                if (std.mem.eql(u8, key, "PAGE_OFFSET")) {
                    return try std.fmt.parseInt(u64, value, 0);
                }
            }
        }
        return error.NoPageOffset;
    }

    fn mmapPage(self: *PageMapManager, paddr: u64, vaddr: u64, flags: MmapFlags, args: MMapArgs) !void {
        if (options.safety) {
            if (!std.mem.Alignment.fromByteUnits(constants.default_page_size).check(paddr)) return error.BadPhysAddrAlignment;
            if (!std.mem.Alignment.fromByteUnits(constants.default_page_size).check(vaddr)) return error.BadVirtAddrAlignment;
        }

        // log.debug("Mapping paddr {x} to vaddr {x}", .{ paddr, vaddr });
        const entry = try self.getPageTableEntry(@bitCast(vaddr), flags, .{});
        if (entry.present) {
            if (entry.getAddr() == @as(u64, @bitCast(paddr)) or args.force) {
                log.warn("Overwriting a present entry (old paddr: 0x{X}) with 0x{X}", .{ entry.getAddr(), @as(u64, @bitCast(paddr)) });
            } else {
                log.err("Overwriting a present entry (old paddr: 0x{X}) with 0x{X}", .{ entry.getAddr(), @as(u64, @bitCast(paddr)) });
                @panic("Overwriting existing entry");
            }
        }

        writeEntry(entry, paddr, flags);
        // log.debug("entry after mapping paddr {x} ({*}): 0x{X}", .{ @as(u64, @bitCast(paddr)), entry, @as(u64, @bitCast(entry.*)) });
    }

    pub fn mmap(self: *PageMapManager, prange: flcn.pmm.PhysMemRange, vrange: VirtMemRange, flags: MmapFlags, args: MMapArgs) !void {
        if (options.safety) {
            if (prange.length != vrange.length) return error.LengthMismatch;
        }

        var physical_addr = prange.start;
        var virtual_addr: u64 = @bitCast(vrange.start);
        const num_pages_to_map = @divExact(prange.length, constants.default_page_size);
        log.debug("Mapping prange {f} to vrange {f} ({d} pages)", .{ prange, vrange, num_pages_to_map });
        for (0..num_pages_to_map) |_| {
            defer physical_addr += constants.default_page_size;
            defer virtual_addr +%= constants.default_page_size;
            self.mmapPage(physical_addr, virtual_addr, flags, args) catch unreachable;
        }
        std.debug.assert(physical_addr == prange.start + prange.length);
    }

    pub fn munmap(self: *PageMapManager, vrange: VirtMemRange) void {
        var virtual_addr: u64 = @bitCast(vrange.start);
        const num_pages_to_map = @divExact(vrange.length, constants.default_page_size);
        log.debug("Unmapping vrange {f} ({d} pages)", .{ vrange, num_pages_to_map });
        for (0..num_pages_to_map) |_| {
            defer virtual_addr +%= constants.default_page_size;
            self.mmapPage(0, virtual_addr, @bitCast(@as(u64, 0)), .{ .force = true }) catch unreachable;
        }
    }

    pub fn virtToPhys(self: *const Self, vaddr: VAddr) PAddr {
        return @as(VAddrSize, @bitCast(vaddr)) - self.page_offset;
    }

    pub fn physToVirt(self: *const Self, paddr: PAddr) VAddr {
        return @bitCast(@as(PAddrSize, paddr) + self.page_offset);
    }

    fn getPageTableEntry(self: *const Self, vaddr: VAddr, flags: MmapFlags, args: struct { create_if_missing: bool = true }) !*PageMapping.Entry {
        // const pml4_vaddr = @as(VAddrSize, @bitCast(self.physToVirt(@intCast(self.root))));
        const pml4_mapping: *PageMapping = @ptrFromInt(self.root);
        log.debug("PML4: {*}", .{pml4_mapping});
        const pdp_mapping = try self.getOrCreateMapping(pml4_mapping, vaddr.pml4_idx, args.create_if_missing);
        log.debug("PDP: {*}", .{pdp_mapping});
        const pd_mapping = try self.getOrCreateMapping(pdp_mapping, vaddr.pdp_idx, args.create_if_missing);
        log.debug("PD: {*}", .{pd_mapping});
        const pt_mapping = try self.getOrCreateMapping(pd_mapping, vaddr.pd_idx, args.create_if_missing);
        log.debug("PT: {*}", .{pt_mapping});
        if (flags.page_size == .large) {
            const pd_mapping_vaddr = self.physToVirt(@intFromPtr(pd_mapping)).toAddr();
            const mapped_pd_mapping: *PageMapping = @ptrFromInt(pd_mapping_vaddr);
            const entry = &mapped_pd_mapping.mappings[vaddr.pd_idx];
            return entry;
        }
        const pt_mapping_vaddr = self.physToVirt(@intFromPtr(pt_mapping)).toAddr();
        const mapped_pt_mapping: *PageMapping = @ptrFromInt(pt_mapping_vaddr);
        const entry = &mapped_pt_mapping.mappings[vaddr.pt_idx];
        return entry;
    }

    fn getOrCreateMapping(self: Self, mapping: *PageMapping, idx: u9, create_if_missing: bool) !*PageMapping {
        const mapping_vaddr = self.physToVirt(@intFromPtr(mapping)).toAddr();
        const mapped_mapping: *PageMapping = @ptrFromInt(mapping_vaddr);
        const next_level: *PageMapping.Entry = &mapped_mapping.mappings[idx];
        if (!next_level.present) {
            if (!create_if_missing) return error.MissingPageMapping;
            const page_ptr = try self.allocate_pages(1);
            writeEntry(next_level, page_ptr, .{ .present = true, .read_write = .read_write });
            return @ptrFromInt(page_ptr);
        }
        const addr = next_level.getAddr();
        return @ptrFromInt(addr);
    }

    fn writeEntry(entry: *PageMapping.Entry, paddr: PAddr, flags: MmapFlags) void {
        entry.* = @bitCast(paddr | @as(u64, @bitCast(flags)));
    }
};

pub const PageAllocator = flcn.allocator.PageAllocator(.fromByteUnits(constants.default_page_size));
