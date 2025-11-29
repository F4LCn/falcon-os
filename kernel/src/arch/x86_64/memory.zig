const std = @import("std");
const log = std.log.scoped(.@"x86_64.memory");
const constants = @import("constants.zig");
const options = @import("options");
const registers = @import("registers.zig");
const flcn = @import("flcn");
const assembly = @import("assembly.zig");
const cpu = @import("cpu.zig");

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
pub const VAddrInt = std.math.IntFittingRange(0, @offsetOf(VAddr, "_pad"));
pub const ReadWrite = enum(u1) {
    read_execute = 0,
    read_write = 1,
};
pub const UserSupervisor = enum(u1) {
    supervisor = 0,
    user = 1,
};
pub const PageType = enum(u1) {
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
    page_size: PageType = .normal,
    global: bool = false,
    _pad: u54 = 0,
    execution_disable: bool = false,
};

pub const PageSize = enum {
    huge,
    large,
    page,
};

pub const CacheControlFlags = struct {
    write_through: bool = false,
    cache_disable: bool = false,
    pat: u1 = 0,
};

pub const CacheControl = enum(u8) {
    uncacheable = 0,
    write_combining = 1,
    write_through = 4,
    write_protected = 5,
    write_back = 6,
    uncached = 7,

    pub fn toFlags(self: CacheControl) CacheControlFlags {
        return cacheTypeMapping.get(self).?;
    }
};

// PAT MAPPING USED:
// PAT|PCD|PWT|PAT SLOT|CACHE TYPE
// 0  |0  |0  |0       |WB
// 0  |0  |1  |1       |WC
// 0  |1  |0  |2       |UC-
// 0  |1  |1  |3       |UC
// 1  |0  |0  |4       |WB (not in mapping)
// 1  |0  |1  |5       |WP
// 1  |1  |0  |6       |UC- (not in mapping)
// 1  |1  |1  |7       |WT

// TODO: enable/write PAT mappings
const PAT = packed struct(u64) {
    pat0: CacheControl = .write_back,
    pat1: CacheControl = .write_combining,
    pat2: CacheControl = .uncached,
    pat3: CacheControl = .uncacheable,
    pat4: CacheControl = .write_back,
    pat5: CacheControl = .write_protected,
    pat6: CacheControl = .uncached,
    pat7: CacheControl = .write_through,
};

pub const CacheTypeToFlagsMapping = std.EnumMap(CacheControl, CacheControlFlags);
pub const cacheTypeMapping: CacheTypeToFlagsMapping = .init(.{
    .write_back = .{
        .pat = 0,
        .cache_disable = false,
        .write_through = false,
    },
    .write_combining = .{
        .pat = 0,
        .cache_disable = false,
        .write_through = true,
    },
    .uncached = .{
        .pat = 0,
        .cache_disable = true,
        .write_through = false,
    },
    .uncacheable = .{
        .pat = 0,
        .cache_disable = true,
        .write_through = true,
    },
    .write_protected = .{
        .pat = 1,
        .cache_disable = false,
        .write_through = true,
    },
    .write_through = .{
        .pat = 1,
        .cache_disable = true,
        .write_through = true,
    },
});

pub const Flags = struct {
    present: bool = false,
    read_write: ReadWrite = .read_write,
    user_supervisor: UserSupervisor = .supervisor,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    size: PageSize = .page,
    cache_control: CacheControl = .write_back,
    global: bool = false,
    execution_disable: bool = false,
};

pub const DefaultMmapFlags: MmapFlags = .{
    .present = true,
    .read_write = .read_write,
};

pub const PageMapping = extern struct {
    pub const PML4Entry = packed struct(u64) {
        present: bool = false,
        read_write: ReadWrite = .read_write,
        user_supervisor: UserSupervisor = .supervisor,
        write_through: bool = false,
        cache_disable: bool = false,
        accessed: bool = false,
        _pad0: u6 = 0,
        addr: u36 = 0,
        _pad1: u15 = 0,
        execution_disable: bool = false,

        pub fn getAddr(self: *const PML4Entry) PAddr {
            return @as(PAddrSize, @intCast(self.addr)) << 12;
        }

        pub fn setAddr(self: *HugePageEntry, addr: u64) void {
            self.addr = @intCast((addr & std.math.maxInt(VAddrInt)) >> 12);
        }

        pub fn print(self: *const PML4Entry) void {
            log.debug("PML4 entry: {*}", .{self});
            log.info("Addr: 0x{X} - 0x{X}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
        }
    };
    pub const HugePageEntry = packed struct(u64) {
        present: bool = false,
        read_write: ReadWrite = .read_write,
        user_supervisor: UserSupervisor = .supervisor,
        write_through: bool = false,
        cache_disable: bool = false,
        accessed: bool = false,
        dirty: bool = false,
        page_size: PageType = .normal,
        global: bool = false,
        _pad0: u3 = 0,
        pat: u1 = 0,
        _reserved: u17 = 0,
        addr: u18 = 0,
        _pad1: u15 = 0,
        execution_disable: bool = false,

        pub fn getEntryAddr(self: *const HugePageEntry) PAddr {
            return @as(PAddrSize, @intCast(self.addr)) << 30;
        }

        pub fn getAddr(self: *const HugePageEntry) PAddr {
            return @as(PAddrSize, @intCast(self.addr)) << 12;
        }

        pub fn setAddr(self: *HugePageEntry, addr: u64) void {
            self.addr = @intCast((addr & std.math.maxInt(VAddrInt)) >> 30);
        }

        pub fn setCacheControl(self: *HugePageEntry, cache_control_type: CacheControl) void {
            const cache_flags = cache_control_type.toFlags();
            self.write_through = cache_flags.write_through;
            self.cache_disable = cache_flags.cache_disable;
            self.pat = cache_flags.pat;
        }

        pub fn print(self: *const HugePageEntry) void {
            log.debug("1GB entry: {*}", .{self});
            log.info("Addr: 0x{X} - 0x{X}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
        }
    };
    pub const LargePageEntry = packed struct(u64) {
        present: bool = false,
        read_write: ReadWrite = .read_write,
        user_supervisor: UserSupervisor = .supervisor,
        write_through: bool = false,
        cache_disable: bool = false,
        accessed: bool = false,
        dirty: bool = false,
        page_size: PageType = .normal,
        global: bool = false,
        _pad0: u3 = 0,
        pat: u1 = 0,
        _reserved: u8 = 0,
        addr: u27 = 0,
        _pad1: u15 = 0,
        execution_disable: bool = false,

        pub fn getAddr(self: *const LargePageEntry) PAddr {
            return @as(PAddrSize, @intCast(self.addr)) << 12;
        }

        pub fn getEntryAddr(self: *const LargePageEntry) PAddr {
            return @as(PAddrSize, @intCast(self.addr)) << 21;
        }

        pub fn setAddr(self: *LargePageEntry, addr: u64) void {
            self.addr = @intCast((addr & std.math.maxInt(VAddrInt)) >> 21);
        }

        pub fn setCacheControl(self: *LargePageEntry, cache_control_type: CacheControl) void {
            const cache_flags = cache_control_type.toFlags();
            self.write_through = cache_flags.write_through;
            self.cache_disable = cache_flags.cache_disable;
            self.pat = cache_flags.pat;
        }

        pub fn print(self: *const LargePageEntry) void {
            log.debug("2MB entry: {*}", .{self});
            log.info("Addr: 0x{X} - 0x{X}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
        }
    };
    pub const PageEntry = packed struct(u64) {
        present: bool = false,
        read_write: ReadWrite = .read_write,
        user_supervisor: UserSupervisor = .supervisor,
        write_through: bool = false,
        cache_disable: bool = false,
        accessed: bool = false,
        dirty: bool = false,
        pat: u1 = 0,
        global: bool = false,
        _pad0: u3 = 0,
        addr: u36 = 0,
        _pad1: u15 = 0,
        execution_disable: bool = false,

        pub fn getAddr(self: *const PageEntry) PAddr {
            return @as(PAddrSize, @intCast(self.addr)) << 12;
        }

        pub fn setAddr(self: *PageEntry, addr: u64) void {
            self.addr = @intCast((addr & std.math.maxInt(VAddrInt)) >> 12);
        }

        pub fn setCacheControl(self: *PageEntry, cache_control_type: CacheControl) void {
            const cache_flags = cache_control_type.toFlags();
            self.write_through = cache_flags.write_through;
            self.cache_disable = cache_flags.cache_disable;
            self.pat = cache_flags.pat;
        }

        pub fn print(self: *const PageEntry) void {
            log.debug("entry: {*}", .{self});
            log.info("Addr: 0x{X} - 0x{X}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
        }
    };
    pub const Entry = packed union {
        pml4: PML4Entry,
        huge: HugePageEntry,
        large: LargePageEntry,
        page: PageEntry,

        pub fn isPresent(self: *const Entry) bool {
            return @as(u64, @bitCast(self)) & 1;
        }
    };
    mappings: [@divExact(constants.default_page_size, @sizeOf(Entry))]Entry,

    comptime {
        std.debug.assert(@bitSizeOf(Entry) == @bitSizeOf(u64));
    }

    pub fn print(self: *const PageMapping, lvl: u8, vaddr: *VAddr) void {
        for (&self.mappings, 0..) |*mapping, idx| {
            if (!mapping.present) continue;
            const entry = if (mapping.page_size == .large) blk: {
                break :blk switch (lvl) {
                    4 => @as(PML4Entry, @bitCast(mapping)),
                    3 => @as(HugePageEntry, @bitCast(mapping)),
                    2 => @as(LargePageEntry, @bitCast(mapping)),
                    1 => mapping,
                    else => unreachable,
                };
            };
            switch (lvl) {
                4 => vaddr.pml4_idx = @intCast(idx),
                3 => vaddr.pdp_idx = @intCast(idx),
                2 => vaddr.pd_idx = @intCast(idx),
                1 => {
                    vaddr.pt_idx = @intCast(idx);
                    log.info("VAddr: 0x{X}: {any}", .{ @as(u64, @bitCast(vaddr.*)), vaddr });
                    entry.print();
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
    page_allocator: PageAllocator,

    pub fn init(page_allocator: PageAllocator) !Self {
        log.info("reading kernel config", .{});
        const page_offset = try readPageOffset();
        const root = registers.readCR(.cr3);
        log.info("Got current pagemap: 0x{X}", .{root});
        if (cpu.hasFeature(.mtrr)) {
            // RANT: I might have understood this wrong,
            // but I thought that MTRRs were declining in favour of the
            // more recent/finegrained control offered by the PAT
            // Turns out that might not be the case and the interplay of the two
            // makes it hard to know how the caching of a memory page will be affected.
            // Simply disabling MTRR (clearing bit 11 of IA32_MTRRdefType) is a *VERY BAD* idea
            // as it will simply force all memory to be uncacheable (what I understand from reading the
            // intel SDM)
            // The plan for now is to figure out how this MTRR business works and implement
            // a sort of basic handling that would let the PAT take charge of the final decision
            // for cache control

            // CAVEAT: PAT will break things if the same page is mapped with different cache types
            // we need some sort of api with ioremap semantics that would ensure that pages with
            // strong caching behaviours are uniquely mapped (mmio mainly, probably DMA to a lesser extent).

            log.debug("cpu has MTRR feature", .{});
            const mtrr_capabilities = assembly.rdmsr(.IA32_MTRRCAP);
            const variable_count = mtrr_capabilities & 0xff;
            const has_fixed = (mtrr_capabilities & (1 << 8)) != 0;

            const mtrr_default_type = assembly.rdmsr(.IA32_MTRRdefType);
            log.debug("MTRR capabilities: {x}. Variable count {d}, has fixed: {any}", .{ mtrr_capabilities, variable_count, has_fixed });
            log.debug("MTRR default type {x}, MTRR {s}", .{ mtrr_default_type, switch (mtrr_default_type & (1 << 11)) {
                0 => "disabled",
                else => "enabled",
            } });
        }
        if (cpu.hasFeature(.pat)) {
            log.debug("cpu has PAT feature", .{});
            const pat: PAT = .{};
            assembly.wrmsr(.IA32_PAT, @bitCast(pat));
            log.info("Writing PAT values {any}", .{pat});
        }
        return .{
            .root = root,
            .levels = 4,
            .page_offset = page_offset,
            .page_allocator = page_allocator,
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

    fn mmapPage(self: *PageMapManager, paddr: u64, vaddr: u64, flags: Flags, args: MMapArgs) !void {
        if (options.safety) {
            if (!std.mem.Alignment.fromByteUnits(constants.default_page_size).check(paddr)) return error.BadPhysAddrAlignment;
            if (!std.mem.Alignment.fromByteUnits(constants.default_page_size).check(vaddr)) return error.BadVirtAddrAlignment;
        }

        try self.writePageTable(@bitCast(vaddr), paddr, flags, .{ .force = args.force });
    }

    pub fn mmap(self: *PageMapManager, prange: flcn.pmm.PhysMemRange, vrange: VirtMemRange, flags: Flags, args: MMapArgs) !void {
        if (options.safety) {
            if (prange.length != vrange.length) return error.LengthMismatch;
        }

        var physical_addr = prange.start;
        var virtual_addr: u64 = @bitCast(vrange.start);
        const page_size: u64 = switch (flags.size) {
            .page => constants.default_page_size,
            .large => 512 * constants.default_page_size,
            .huge => 512 * 512 * constants.default_page_size,
        };
        const num_pages_to_map = @divExact(prange.length, page_size);
        log.debug("Mapping prange {f} to vrange {f} ({d} pages)", .{ prange, vrange, num_pages_to_map });
        for (0..num_pages_to_map) |_| {
            defer physical_addr += page_size;
            defer virtual_addr +%= page_size;
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
            self.mmapPage(0, virtual_addr, .{}, .{ .force = true }) catch unreachable;
        }
    }

    pub fn virtToPhys(self: *const Self, vaddr: VAddr) PAddr {
        return @as(VAddrSize, @bitCast(vaddr)) - self.page_offset;
    }

    pub fn physToVirt(self: *const Self, paddr: PAddr) VAddr {
        return @bitCast(@as(PAddrSize, paddr) + self.page_offset);
    }

    fn writePageTable(self: *const Self, vaddr: VAddr, paddr: PAddr, flags: Flags, args: struct { create_if_missing: bool = true, force: bool = false }) !void {
        const pml4_mapping: *PageMapping = @ptrFromInt(self.physToVirt(self.root).toAddr());
        log.debug("PML4: 0x{x} ({*})", .{ self.root, pml4_mapping });
        const pml4_entry = &pml4_mapping.mappings[vaddr.pml4_idx];

        const pdp_mapping_addr = try self.getOrCreateMapping2(pml4_entry, args.create_if_missing);
        const pdp_mapping: *PageMapping = @ptrFromInt(self.physToVirt(pdp_mapping_addr).toAddr());
        log.debug("PDP: 0x{x} ({*})", .{ pdp_mapping_addr, pdp_mapping });
        const pdp_entry = &pdp_mapping.mappings[vaddr.pdp_idx];
        if (flags.size == .huge) {
            const huge_page_entry = &pdp_entry.huge;
            if (!huge_page_entry.present) {
                @branchHint(.likely);
                var pdp_copy = huge_page_entry.*;
                pdp_copy.setAddr(paddr);
                pdp_copy.setCacheControl(.write_back);
                pdp_copy.present = true;
                writeEntry(@ptrCast(pdp_entry), @bitCast(pdp_copy));
                return;
            }
            if (!args.force) {
                @branchHint(.likely);
                log.err("overwriting an existing PDP entry {any}", .{pdp_entry});
                @panic("mmap overwrite");
            }

            var pdp_copy = huge_page_entry.*;
            pdp_copy.setAddr(paddr);
            pdp_copy.setCacheControl(.write_back);
            pdp_copy.present = true;
            writeEntry(@ptrCast(pdp_entry), @bitCast(pdp_copy));
            return;
        }

        const pd_mapping_addr = try self.getOrCreateMapping2(pdp_entry, args.create_if_missing);
        const pd_mapping: *PageMapping = @ptrFromInt(self.physToVirt(pd_mapping_addr).toAddr());
        log.debug("PD: 0x{x} ({*})", .{ pd_mapping_addr, pd_mapping });
        const pd_entry = &pd_mapping.mappings[vaddr.pd_idx];
        if (flags.size == .large) {
            const large_page_entry = &pd_entry.large;
            if (!large_page_entry.present) {
                @branchHint(.likely);
                var pd_copy = large_page_entry.*;
                pd_copy.setAddr(paddr);
                pd_copy.setCacheControl(.write_back);
                pd_copy.present = true;
                writeEntry(@ptrCast(pd_entry), @bitCast(pd_copy));
                return;
            }
            if (!args.force) {
                @branchHint(.likely);
                log.err("overwriting an existing PD entry {any}", .{pd_entry});
                @panic("mmap overwrite");
            }
            var pd_copy = large_page_entry.*;
            pd_copy.setAddr(paddr);
            pd_copy.setCacheControl(.write_back);
            pd_copy.present = true;
            writeEntry(@ptrCast(pd_entry), @bitCast(pd_copy));
            return;
        }

        const pt_mapping_addr = try self.getOrCreateMapping2(pd_entry, args.create_if_missing);
        const pt_mapping: *PageMapping = @ptrFromInt(self.physToVirt(pt_mapping_addr).toAddr());
        log.debug("PT: 0x{x} ({*})", .{ pt_mapping_addr, pt_mapping });
        const pt_entry = &pt_mapping.mappings[vaddr.pt_idx];
        if (flags.size == .page) {
            const page_entry = &pt_entry.page;
            if (!page_entry.present) {
                @branchHint(.likely);
                var pt_copy = page_entry.*;
                pt_copy.setAddr(paddr);
                pt_copy.setCacheControl(.write_back);
                pt_copy.present = true;
                writeEntry(@ptrCast(pt_entry), @bitCast(pt_copy));
                return;
            }
            if (!args.force) {
                @branchHint(.likely);
                log.err("overwriting an existing PT entry {any}", .{pt_entry});
                @panic("mmap overwrite");
            }
            var pt_copy = page_entry.*;
            pt_copy.setAddr(paddr);
            pt_copy.setCacheControl(.write_back);
            pt_copy.present = true;
            writeEntry(@ptrCast(pt_entry), @bitCast(pt_copy));
            return;
        }

        unreachable;
    }

    fn getPageTableEntry(self: *const Self, vaddr: VAddr, flags: MmapFlags, args: struct { create_if_missing: bool = true }) !*PageMapping.Entry {
        // const pml4_vaddr = @as(VAddrSize, @bitCast(self.physToVirt(@intCast(self.root))));
        const pml4_mapping: *PageMapping = @ptrFromInt(self.root);
        log.debug("PML4: {*}", .{pml4_mapping});

        const pdp_mapping = try self.getOrCreateMapping(pml4_mapping, vaddr.pml4_idx, args.create_if_missing);
        log.debug("PDP: {*}", .{pdp_mapping});
        const pd_mapping = try self.getOrCreateMapping(pdp_mapping, vaddr.pdp_idx, args.create_if_missing);
        log.debug("PD: {*}", .{pd_mapping});
        if (flags.page_size == .large) {
            const pd_mapping_vaddr = self.physToVirt(@intFromPtr(pd_mapping)).toAddr();
            const mapped_pd_mapping: *PageMapping = @ptrFromInt(pd_mapping_vaddr);
            const entry = &mapped_pd_mapping.mappings[vaddr.pd_idx].large;
            return entry;
        }

        const pt_mapping = try self.getOrCreateMapping(pd_mapping, vaddr.pd_idx, args.create_if_missing);
        log.debug("PT: {*}", .{pt_mapping});
        const pt_mapping_vaddr = self.physToVirt(@intFromPtr(pt_mapping)).toAddr();
        const mapped_pt_mapping: *PageMapping = @ptrFromInt(pt_mapping_vaddr);
        const entry = &mapped_pt_mapping.mappings[vaddr.pt_idx];
        return entry;
    }

    fn getOrCreateMapping2(self: Self, entry: *PageMapping.Entry, create_if_missing: bool) !u64 {
        log.debug("create mapping {*}", .{entry});
        const entry_page = &entry.page;
        if (!entry_page.present) {
            log.debug("Entry is not present {any}", .{entry_page});
            if (!create_if_missing) return error.MissingPageMapping;
            const page_ptr = try self.page_allocator.allocate(1, .{ .zero = true });
            const page_paddr = self.virtToPhys(@bitCast(@intFromPtr(page_ptr)));
            var entry_copy = entry_page.*;
            entry_copy.setAddr(page_paddr);
            entry_copy.setCacheControl(.write_back);
            entry_copy.present = true;
            log.debug("Filling entry data {any}", .{entry_copy});
            writeEntry(@ptrCast(entry_page), @bitCast(entry_copy));
            return page_paddr;
        }
        return entry_page.getAddr();
    }

    fn getOrCreateMapping(self: Self, mapping: *PageMapping, idx: u9, create_if_missing: bool) !*PageMapping {
        log.debug("create mapping {*} {d}", .{ mapping, idx });
        const mapping_vaddr = self.physToVirt(@intFromPtr(mapping)).toAddr();
        const mapped_mapping: *PageMapping = @ptrFromInt(mapping_vaddr);
        const entry: *PageMapping.PageEntry = &mapped_mapping.mappings[idx].page;
        log.debug("Working on entry {d} of mapping {*}", .{ idx, mapping });
        if (!entry.present) {
            log.debug("Entry is not present {any}", .{entry});
            if (!create_if_missing) return error.MissingPageMapping;
            const page_ptr = try self.page_allocator.allocate(1, .{ .zero = true });
            const page_paddr = self.virtToPhys(@bitCast(@intFromPtr(page_ptr)));
            var entry_copy = entry.*;
            entry_copy.setAddr(page_paddr);
            entry_copy.setCacheControl(.write_back);
            entry_copy.present = true;
            log.debug("Filling entry data {any}", .{entry_copy});
            writeEntry(@ptrCast(entry), @bitCast(entry_copy));
            return @ptrFromInt(page_paddr);
        }
        const addr = entry.getAddr();
        return @ptrFromInt(addr);
    }

    inline fn writeEntry(entry: *u64, val: u64) void {
        entry.* = val;
    }
};

pub const PageAllocator = flcn.allocator.PageAllocator(.fromByteUnits(constants.default_page_size));
