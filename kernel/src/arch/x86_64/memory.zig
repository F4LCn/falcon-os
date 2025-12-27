const std = @import("std");
const constants = @import("constants.zig");
const options = @import("options");
const registers = @import("registers.zig");
const flcn = @import("flcn");
const assembly = @import("assembly.zig");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.@"x86_64.memory");

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
pub const VAddrInt = std.math.IntFittingRange(0, (1 << @bitOffsetOf(VAddr, "_pad")) - 1);
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
    read_write: ReadWrite = .read_execute,
    user_supervisor: UserSupervisor = .supervisor,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    size: PageSize = .page,
    cache_control: CacheControl = .write_back,
    global: bool = false,
    execution_disable: bool = false,

    pub fn extend(self: Flags, extension: struct {
        present: ?bool = null,
        read_write: ?ReadWrite = null,
        user_supervisor: ?UserSupervisor = null,
        write_through: ?bool = null,
        cache_disable: ?bool = null,
        accessed: ?bool = null,
        dirty: ?bool = null,
        size: ?PageSize = null,
        cache_control: ?CacheControl = null,
        global: ?bool = null,
        execution_disable: ?bool = null,
    }) Flags {
        return .{
            .present = if (extension.present) |v| v else self.present,
            .read_write = if (extension.read_write) |v| v else self.read_write,
            .user_supervisor = if (extension.user_supervisor) |v| v else self.user_supervisor,
            .write_through = if (extension.write_through) |v| v else self.write_through,
            .cache_disable = if (extension.cache_disable) |v| v else self.cache_disable,
            .size = if (extension.size) |v| v else self.size,
            .cache_control = if (extension.cache_control) |v| v else self.cache_control,
            .global = if (extension.global) |v| v else self.global,
            .execution_disable = if (extension.execution_disable) |v| v else self.execution_disable,
        };
    }
};

pub const DefaultFlags: Flags = .{
    .present = true,
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

        pub fn getEntryAddr(self: *const PML4Entry) PAddr {
            return @as(PAddrSize, @intCast(self.addr)) << 12;
        }

        pub fn setAddr(self: *HugePageEntry, addr: u64) void {
            self.addr = @intCast((addr & std.math.maxInt(VAddrInt)) >> 12);
        }

        pub fn print(self: *const PML4Entry) void {
            log.debug("PML4 entry: {*}", .{self});
            log.debug("Addr: 0x{X} - 0x{X}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
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
            self.addr = @intCast(addr >> 30);
        }

        pub fn setFlags(self: *HugePageEntry, flags: Flags) void {
            log.debug("setting PDP entry flags {any}", .{flags});
            self.present = flags.present;
            self.read_write = flags.read_write;
            self.user_supervisor = flags.user_supervisor;
            self.write_through = flags.write_through;
            self.cache_disable = flags.cache_disable;
            self.page_size = if (flags.size == .huge) .large else .normal;
            self.global = flags.global;
            self.execution_disable = flags.execution_disable;
            self.setCacheControl(flags.cache_control);
        }

        fn setCacheControl(self: *HugePageEntry, cache_control_type: CacheControl) void {
            const cache_flags = cache_control_type.toFlags();
            log.debug("setting cache control flags {any}", .{cache_flags});
            self.write_through = cache_flags.write_through;
            self.cache_disable = cache_flags.cache_disable;
            self.pat = cache_flags.pat;
        }

        pub fn print(self: *const HugePageEntry) void {
            log.debug("1GB entry: {*}", .{self});
            log.debug("Addr: 0x{X} - 0x{X}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
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
            self.addr = @intCast(addr >> 21);
        }

        pub fn setFlags(self: *LargePageEntry, flags: Flags) void {
            log.debug("setting PD entry flags {any}", .{flags});
            self.present = flags.present;
            self.read_write = flags.read_write;
            self.user_supervisor = flags.user_supervisor;
            self.write_through = flags.write_through;
            self.cache_disable = flags.cache_disable;
            self.page_size = if (flags.size == .large) .large else .normal;
            self.global = flags.global;
            self.execution_disable = flags.execution_disable;
            self.setCacheControl(flags.cache_control);
        }

        fn setCacheControl(self: *LargePageEntry, cache_control_type: CacheControl) void {
            const cache_flags = cache_control_type.toFlags();
            log.debug("setting cache control flags {any}", .{cache_flags});
            self.write_through = cache_flags.write_through;
            self.cache_disable = cache_flags.cache_disable;
            self.pat = cache_flags.pat;
        }

        pub fn print(self: *const LargePageEntry) void {
            log.debug("2MB entry: {*}", .{self});
            log.debug("Addr: 0x{X} - 0x{X}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
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

        pub fn getEntryAddr(self: *const PageEntry) PAddr {
            return @as(PAddrSize, @intCast(self.addr)) << 12;
        }

        pub fn setAddr(self: *PageEntry, addr: u64) void {
            log.debug("addr mask {x}", .{std.math.maxInt(VAddrInt)});
            log.debug("setting PT addr {x}", .{addr});
            self.addr = @intCast(addr >> 12);
        }

        pub fn setFlags(self: *PageEntry, flags: Flags) void {
            log.debug("setting PT entry flags {any}", .{flags});
            self.present = flags.present;
            self.read_write = flags.read_write;
            self.user_supervisor = flags.user_supervisor;
            self.write_through = flags.write_through;
            self.cache_disable = flags.cache_disable;
            self.global = flags.global;
            self.execution_disable = flags.execution_disable;
            self.setCacheControl(flags.cache_control);
        }

        fn setCacheControl(self: *PageEntry, cache_control_type: CacheControl) void {
            const cache_flags = cache_control_type.toFlags();
            log.debug("setting cache control flags {any}", .{cache_flags});
            self.write_through = cache_flags.write_through;
            self.cache_disable = cache_flags.cache_disable;
            self.pat = cache_flags.pat;
        }

        pub fn print(self: *const PageEntry) void {
            log.debug("entry: {*}", .{self});
            log.debug("Addr: 0x{X} - 0x{X}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
        }
    };
    pub const Entry = packed union {
        pml4: PML4Entry,
        huge: HugePageEntry,
        large: LargePageEntry,
        page: PageEntry,
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
                    log.debug("VAddr: 0x{X}: {any}", .{ @as(u64, @bitCast(vaddr.*)), vaddr });
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

pub fn init() void {
    initMTRR();
    initPAT();
}

const MTRRCapabilites = packed struct(u64) {
    variable_ranges_count: u8,
    fixed_ranges_supported: bool,
    _res0: u1,
    write_combine_supported: bool,
    smrr_supported: bool,
    _res1: u52,
};
const MTRRDefType = packed struct(u64) {
    default_type: CacheControl,
    _res0: u2,
    fixed_ranges_enabled: bool,
    enabled: bool,
    _res1: u52,
};
const MTRRFixed = packed struct(u64) {
    range0: CacheControl,
    range1: CacheControl,
    range2: CacheControl,
    range3: CacheControl,
    range4: CacheControl,
    range5: CacheControl,
    range6: CacheControl,
    range7: CacheControl,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("0:{any} 1:{any} 2:{any} 3:{any} 4:{any} 5:{any} 6:{any} 7:{any}", .{
            self.range0,
            self.range1,
            self.range2,
            self.range3,
            self.range4,
            self.range5,
            self.range6,
            self.range7,
        });
    }
};
const MTRRPhysBase = packed struct(u64) {
    typ: CacheControl,
    _res0: u4,
    addr: VAddrInt,
    _res1: @Int(.unsigned, @bitSizeOf(u64) - @bitSizeOf(CacheControl) - @bitSizeOf(u4) - @bitSizeOf(VAddrInt)),

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("addr: 0x{x}, type: {any}", .{ @as(u64, @intCast(self.addr)) << 12, self.typ });
    }
};
const MTRRPhysMask = packed struct(u64) {
    _res0: u8,
    _res1: u3,
    valid: bool,
    mask: VAddrInt,
    _res2: @Int(.unsigned, @bitSizeOf(u64) - @bitSizeOf(u8) - @bitSizeOf(u3) - @bitSizeOf(VAddrInt) - 1),

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("mask: 0x{x}, valid: {any}", .{ @as(u64, @intCast(self.mask)) << 12, self.valid });
    }
};
fn initMTRR() void {
    if (cpu.hasFeature(.mtrr)) {
        // RANT: I might have understood this wrong,
        // but I thought that MTRRs were declining in favour of the
        // more recent/finegrained control offered by the PAT
        // Turns out that might not be the case and the interplay of the two
        // makes it hard to know how the caching of a memory page will be affected.
        // Simply disabling MTRR (clearing bit 11 of MTRRdefType) is a *VERY BAD* idea
        // as it will simply force all memory to be uncacheable (what I understand from reading the
        // intel SDM)
        // The plan for now is to figure out how this MTRR business works and implement
        // a sort of basic handling that would let the PAT take charge of the final decision
        // for cache control

        // CAVEAT: PAT will break things if the same page is mapped with different cache types
        // we need some sort of api with ioremap semantics that would ensure that pages with
        // strong caching behaviours are uniquely mapped (mmio mainly, probably DMA to a lesser extent).

        // NOTE: the plan for now is to hope the bios/uefi inits the MTRR to something sane
        // like write-back for (at least) all variable ranges. If not maybe we should disable
        // the variable ranges, set the default type to write-back
        // we do not care about fixed ranges unless should they overlap a framebuffer/BAR/mmio
        // device space then we're in trouble.

        log.debug("cpu has MTRR feature", .{});
        const mtrr_capabilities: MTRRCapabilites = @bitCast(assembly.rdmsr(.MTRRCAP));
        log.debug("MTRR capabilities: {any}", .{mtrr_capabilities});

        const mtrr_default_type: MTRRDefType = @bitCast(assembly.rdmsr(.MTRRdefType));
        log.debug("MTRR default type {any}", .{mtrr_default_type});

        const mtrr_fixed_64k: MTRRFixed = @bitCast(assembly.rdmsr(.MTRRfix64K_00000));
        log.debug("MTRR fixed 64k {f}", .{mtrr_fixed_64k});

        for ([_]cpu.MSR{ .MTRRfix16K_80000, .MTRRfix16K_A0000 }) |msr| {
            const mtrr_fixed_16k: MTRRFixed = @bitCast(assembly.rdmsr(msr));
            log.debug("MTRR fixed 16k {f}", .{mtrr_fixed_16k});
        }

        for ([_]cpu.MSR{
            .MTRRfix4K_C0000,
            .MTRRfix4K_C8000,
            .MTRRfix4K_D0000,
            .MTRRfix4K_D8000,
            .MTRRfix4K_E0000,
            .MTRRfix4K_E8000,
            .MTRRfix4K_F0000,
            .MTRRfix4K_F8000,
        }) |msr| {
            const mtrr_fixed_4k: MTRRFixed = @bitCast(assembly.rdmsr(msr));
            log.debug("MTRR fixed 4k {f}", .{mtrr_fixed_4k});
        }

        for (0..mtrr_capabilities.variable_ranges_count) |i| {
            const msr_physbase: cpu.MSR = @enumFromInt(@intFromEnum(cpu.MSR.MTRR_PHYSBASE0) + 2 * i);
            const msr_physmask: cpu.MSR = @enumFromInt(@intFromEnum(cpu.MSR.MTRR_PHYSMASK0) + 2 * i + 1);
            const physbase: MTRRPhysBase = @bitCast(assembly.rdmsr(msr_physbase));
            const physmask: MTRRPhysMask = @bitCast(assembly.rdmsr(msr_physmask));

            log.debug("MTRR var#{d} base: {f} mask: {f}", .{ i, physbase, physmask });
        }
        log.info("MTRR checked", .{});
    }
}

fn initPAT() void {
    if (cpu.hasFeature(.pat)) {
        log.debug("cpu has PAT feature", .{});
        const pat: PAT = .{};
        assembly.wrmsr(.PAT, @bitCast(pat));
        log.debug("Writing PAT values {any}", .{pat});
        log.info("PAT initialized", .{});
    }
}

var env = @extern([*]u8, .{ .name = "env", .visibility = .hidden });
pub const VirtualMemoryManager = flcn.vmm.VirtualMemoryManager(VAddr, VAddrSize);
pub const VirtMemRange = VirtualMemoryManager.VirtMemRange;
pub const MMapArgs = struct {
    remap: bool = false,
};
pub const PageMapManager = struct {
    const Self = @This();
    root: u64,
    levels: u8,
    page_offset: VAddrSize,
    page_allocator: PageAllocator,

    pub fn init(page_allocator: PageAllocator) !Self {
        const page_offset = try readPageOffset();
        const root = registers.readCR(.cr3);
        log.debug("current pagemap: 0x{X}", .{root});
        return .{
            .root = root,
            .levels = 4,
            .page_offset = page_offset,
            .page_allocator = page_allocator,
        };
    }

    fn readPageOffset() !VAddrSize {
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

        try self.writePageTable(@bitCast(vaddr), paddr, flags, .{ .remap = args.remap });
        assembly.invalidateVirtualAddress(vaddr);
    }

    pub fn mmap(self: *PageMapManager, prange: flcn.pmm.PhysMemRange, vrange: VirtMemRange, flags: Flags, args: MMapArgs) !void {
        if (options.safety) {
            if (prange.length != vrange.length) return error.LengthMismatch;
        }

        var physical_addr = prange.start;
        var virtual_addr: u64 = @bitCast(vrange.start);
        const page_size: u64 = switch (flags.size) {
            .page => constants.default_page_size,
            .large => constants.large_page_size,
            .huge => constants.huge_page_size,
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
            self.mmapPage(0, virtual_addr, .{}, .{ .remap = true }) catch unreachable;
        }
    }

    fn remapPage(self: *PageMapManager, vaddr: u64, flags: Flags) !void {
        if (options.safety) {
            if (!std.mem.Alignment.fromByteUnits(constants.default_page_size).check(vaddr)) return error.BadVirtAddrAlignment;
        }

        const entry = try self.getEntry(@bitCast(vaddr), flags);
        var entry_addr: *u64 = undefined;
        var entry_value: u64 = undefined;
        switch (flags.size) {
            .page => {
                const pt_entry = &entry.page;
                var pt_copy = pt_entry.*;
                pt_copy.setFlags(flags);
                entry_addr = @ptrCast(pt_entry);
                entry_value = @bitCast(pt_copy);
                log.debug("remapping pt entry {any}", .{pt_copy});
            },
            .large => {
                const pd_entry = &entry.large;
                var pd_copy = pd_entry.*;
                pd_copy.setFlags(flags);
                entry_addr = @ptrCast(pd_entry);
                entry_value = @bitCast(pd_copy);
                log.debug("remapping pd entry {any}", .{pd_copy});
            },
            .huge => {
                const pdp_entry = &entry.huge;
                var pdp_copy = pdp_entry.*;
                pdp_copy.setFlags(flags);
                entry_addr = @ptrCast(pdp_entry);
                entry_value = @bitCast(pdp_copy);
                log.debug("remapping pdp entry {any}", .{pdp_copy});
            },
        }
        writeEntry(entry_addr, entry_value);
        assembly.invalidateVirtualAddress(vaddr);
    }

    pub fn remap(self: *PageMapManager, vrange: VirtMemRange, flags: Flags) !void {
        var virtual_addr: u64 = @bitCast(vrange.start);
        const page_size: u64 = switch (flags.size) {
            .page => constants.default_page_size,
            .large => 512 * constants.default_page_size,
            .huge => 512 * 512 * constants.default_page_size,
        };
        const num_pages_to_map = @divExact(vrange.length, page_size);
        log.debug("remapping vrange {f} ({d} pages) with flags {any}", .{ vrange, num_pages_to_map, flags });
        for (0..num_pages_to_map) |_| {
            defer virtual_addr +%= page_size;
            try self.remapPage(virtual_addr, flags);
        }
    }

    pub fn virtToPhys(self: *const Self, vaddr: VAddr) PAddr {
        return @as(VAddrSize, @bitCast(vaddr)) - self.page_offset;
    }

    pub fn physToVirt(self: *const Self, paddr: PAddr) VAddr {
        return @bitCast(@as(PAddrSize, paddr) + self.page_offset);
    }

    fn getEntry(self: *const Self, vaddr: VAddr, flags: Flags) !*PageMapping.Entry {
        const pml4_mapping: *PageMapping = @ptrFromInt(self.physToVirt(self.root).toAddr());
        log.debug("PML4: 0x{x} ({*})", .{ self.root, pml4_mapping });
        const pml4_entry = &pml4_mapping.mappings[vaddr.pml4_idx];

        const pdp_mapping_addr = try self.getOrCreateMapping(pml4_entry, false);
        const pdp_mapping: *PageMapping = @ptrFromInt(self.physToVirt(pdp_mapping_addr).toAddr());
        log.debug("PDP: 0x{x} ({*})", .{ pdp_mapping_addr, pdp_mapping });
        const pdp_entry = &pdp_mapping.mappings[vaddr.pdp_idx];
        if (flags.size == .huge) {
            return pdp_entry;
        }

        const pd_mapping_addr = try self.getOrCreateMapping(pdp_entry, false);
        const pd_mapping: *PageMapping = @ptrFromInt(self.physToVirt(pd_mapping_addr).toAddr());
        log.debug("PD: 0x{x} ({*})", .{ pd_mapping_addr, pd_mapping });
        const pd_entry = &pd_mapping.mappings[vaddr.pd_idx];
        if (flags.size == .large) {
            return pd_entry;
        }

        const pt_mapping_addr = try self.getOrCreateMapping(pd_entry, false);
        const pt_mapping: *PageMapping = @ptrFromInt(self.physToVirt(pt_mapping_addr).toAddr());
        log.debug("PT: 0x{x} ({*})", .{ pt_mapping_addr, pt_mapping });
        const pt_entry = &pt_mapping.mappings[vaddr.pt_idx];
        if (flags.size == .page) {
            return pt_entry;
        }

        return error.MappingNotFound;
    }

    fn writePageTable(self: *const Self, vaddr: VAddr, paddr: PAddr, flags: Flags, args: struct { create_if_missing: bool = true, remap: bool = false }) !void {
        const pml4_mapping: *PageMapping = @ptrFromInt(self.physToVirt(self.root).toAddr());
        log.debug("PML4: 0x{x} ({*})", .{ self.root, pml4_mapping });
        const pml4_entry = &pml4_mapping.mappings[vaddr.pml4_idx];

        const pdp_mapping_addr = try self.getOrCreateMapping(pml4_entry, args.create_if_missing);
        const pdp_mapping: *PageMapping = @ptrFromInt(self.physToVirt(pdp_mapping_addr).toAddr());
        log.debug("PDP: 0x{x} ({*})", .{ pdp_mapping_addr, pdp_mapping });
        const pdp_entry = &pdp_mapping.mappings[vaddr.pdp_idx];
        if (flags.size == .huge) {
            const huge_page_entry = &pdp_entry.huge;
            if (!huge_page_entry.present) {
                @branchHint(.likely);
                var pdp_copy = huge_page_entry.*;
                pdp_copy.setAddr(paddr);
                pdp_copy.setFlags(flags);
                log.debug("writing PDP entry {any}", .{pdp_copy});
                writeEntry(@ptrCast(pdp_entry), @bitCast(pdp_copy));
                return;
            }
            if (!args.remap) {
                @branchHint(.likely);
                log.err("overwriting an existing PDP entry {any}", .{pdp_entry});
                @panic("mmap overwrite");
            }

            var pdp_copy = huge_page_entry.*;
            pdp_copy.setAddr(paddr);
            pdp_copy.setFlags(flags);
            log.debug("writing existing PDP entry {any}", .{pdp_copy});
            writeEntry(@ptrCast(pdp_entry), @bitCast(pdp_copy));
            return;
        }

        const pd_mapping_addr = try self.getOrCreateMapping(pdp_entry, args.create_if_missing);
        const pd_mapping: *PageMapping = @ptrFromInt(self.physToVirt(pd_mapping_addr).toAddr());
        log.debug("PD: 0x{x} ({*})", .{ pd_mapping_addr, pd_mapping });
        const pd_entry = &pd_mapping.mappings[vaddr.pd_idx];
        if (flags.size == .large) {
            const large_page_entry = &pd_entry.large;
            if (!large_page_entry.present) {
                @branchHint(.likely);
                var pd_copy = large_page_entry.*;
                pd_copy.setAddr(paddr);
                pd_copy.setFlags(flags);
                log.debug("writing PD entry {any}", .{pd_copy});
                writeEntry(@ptrCast(pd_entry), @bitCast(pd_copy));
                return;
            }
            if (!args.remap) {
                @branchHint(.likely);
                log.err("overwriting an existing PD entry {any}", .{pd_entry});
                @panic("mmap overwrite");
            }
            var pd_copy = large_page_entry.*;
            pd_copy.setAddr(paddr);
            pd_copy.setFlags(flags);
            log.debug("writing existing PD entry {any}", .{pd_entry});
            writeEntry(@ptrCast(pd_entry), @bitCast(pd_copy));
            return;
        }

        const pt_mapping_addr = try self.getOrCreateMapping(pd_entry, args.create_if_missing);
        const pt_mapping: *PageMapping = @ptrFromInt(self.physToVirt(pt_mapping_addr).toAddr());
        log.debug("PT: 0x{x} ({*})", .{ pt_mapping_addr, pt_mapping });
        const pt_entry = &pt_mapping.mappings[vaddr.pt_idx];
        if (flags.size == .page) {
            const page_entry = &pt_entry.page;
            if (!page_entry.present) {
                @branchHint(.likely);
                var pt_copy = page_entry.*;
                pt_copy.setAddr(paddr);
                pt_copy.setFlags(flags);
                log.debug("writing PT entry {any}", .{pt_copy});
                writeEntry(@ptrCast(pt_entry), @bitCast(pt_copy));
                return;
            }
            if (!args.remap) {
                @branchHint(.likely);
                log.err("overwriting an existing PT entry {any}", .{pt_entry});
                @panic("mmap overwrite");
            }
            var pt_copy = page_entry.*;
            pt_copy.setAddr(paddr);
            pt_copy.setFlags(flags);
            log.debug("writing existing PT entry {any}", .{pt_copy});
            writeEntry(@ptrCast(pt_entry), @bitCast(pt_copy));
            return;
        }

        unreachable;
    }

    fn getOrCreateMapping(self: Self, entry: *PageMapping.Entry, create_if_missing: bool) !u64 {
        log.debug("get or create mapping {*}", .{entry});
        const entry_page = &entry.page;
        if (!entry_page.present) {
            log.debug("entry is not present {any}", .{entry_page});
            if (!create_if_missing) return error.MissingPageMapping;
            const page_ptr = try self.page_allocator.allocate(1, .{ .zero = true });
            const page_paddr = self.virtToPhys(@bitCast(@intFromPtr(page_ptr)));
            var entry_copy = entry_page.*;
            entry_copy.setAddr(page_paddr);
            entry_copy.present = true;
            log.debug("filling entry data {any}", .{entry_copy});
            writeEntry(@ptrCast(entry_page), @bitCast(entry_copy));
            return page_paddr;
        }
        return entry_page.getAddr();
    }

    inline fn writeEntry(entry: *u64, val: u64) void {
        entry.* = val;
        log.debug("Written entry {*} = 0x{x}", .{ entry, val });
    }
};

pub const PageAllocator = flcn.allocator.PageAllocator(.fromByteUnits(constants.default_page_size));
