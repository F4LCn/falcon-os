const std = @import("std");
const assembly = @import("assembly.zig");

pub const CpuId = u32;

pub const IdentificationData = struct {
    apic_id: CpuId,
    lapic_addr: u32,
};

pub const CpuData = extern struct {
    // NOTE: Should contain all cpu related data
    // included in core CpuData struct
    // TSS, APIC controller
    apic_base_addr: u32,
    apic_id: CpuId,

    pub fn init(_: CpuId, id_data: IdentificationData) CpuData {
        return .{
            .apic_base_addr = id_data.lapic_addr,
            .apic_id = id_data.apic_id,
        };
    }
};

const max_basic_level = 32;
const max_extended_level = 32;
const max_fn04_level = 8;
const max_fn0b_level = 4;
const max_fn12_level = 4;
const max_fn14_level = 4;
const max_fn8000001d_level = 4;

pub const Feature = enum {
    fpu, // floating point unit
    vme, // virtual mode extension
    de, // debugging extension
    pse, // page size extension
    tsc, // time-stamp counter
    msr, // model-specific regsisters, rdmsr/wrmsr supported
    pae, // physical address extension
    mce, // machine check exception
    cx8, // cmpxchg8b instruction supported
    apic, // apic support
    sep, // sysenter / sysexit instructions supported
    mtrr, // memory type range registers
    pge, // page global enable
    mca, // machine check architecture
    cmov, // cmovxx instructions supported
    pat, // page attribute table
    pse36, // 36-bit page address extension
    pn, // processor serial # implemented (intel p3 only)
    clflush, // clflush instruction supported
    dts, // debug store supported
    acpi, // acpi support (power states)
    mmx, // mmx instruction set supported
    fxsr, // fxsave / fxrstor supported
    sse, // streaming-simd extensions (sse) supported
    sse2, // sse2 instructions supported
    ss, // self-snoop
    ht, // hyper-threading supported (but might be disabled)
    tm, // thermal monitor
    ia64, // ia64 supported (itanium only)
    pbe, // pending-break enable
    pni, // pni (sse3) instructions supported
    pclmul, // pclmulqdq instruction supported
    dts64, // 64-bit debug store supported
    monitor, // monitor / mwait supported
    ds_cpl, // cpl qualified debug store
    vmx, // virtualization technology supported
    smx, // safer mode exceptions
    est, // enhanced speedstep
    tm2, // thermal monitor 2
    ssse3, // ssse3 instructionss supported (this is different from sse3!)
    cid, // context id supported
    cx16, // cmpxchg16b instruction supported
    xtpr, // send task priority messages disable
    pdcm, // performance capabilities msr supported
    pcid, // process context identifiers
    dca, // direct cache access supported
    sse4_1, // sse 4.1 instructions supported
    sse4_2, // sse 4.2 instructions supported
    syscall, // syscall / sysret instructions supported
    xd, // execute disable bit supported
    movbe, // movbe instruction supported
    popcnt, // popcnt instruction supported
    aes, // aes* instructions supported
    xsave, // xsave/xrstor/etc instructions supported
    osxsave, // non-privileged copy of osxsave supported
    avx, // advanced vector extensions supported
    mmxext, // amd mmx-extended instructions supported
    amd3dnow, // amd 3dnow! instructions supported
    amd3dnowext, // amd 3dnow! extended instructions supported
    nx, // no-execute bit supported
    fxsr_opt, // ffxsr: fxsave and fxrstor optimizations
    rdtscp, // rdtscp instruction supported (amd-only)
    lm, // long mode (x86_64/em64t) supported
    lahf_lm, // lahf/sahf supported in 64-bit mode
    cmp_legacy, // core multi-processing legacy mode
    svm, // amd secure virtual machine
    abm, // lzcnt instruction support
    misalignsse, // misaligned sse supported
    sse4a, // sse 4a from amd
    amd3dnowprefetch, // prefetch/prefetchw support
    osvw, // os visible workaround (amd)
    ibs, // instruction-based sampling
    sse5, // sse 5 instructions supported (deprecated, will never be 1)
    skinit, // skinit / stgi supported
    wdt, // watchdog timer support
    ts, // temperature sensor
    fid, // frequency id control
    vid, // voltage id control
    ttp, // thermtrip
    tm_amd, // amd-specified hardware thermal control
    stc, // software thermal control
    steps100mhz, // 100 mhz multiplier control
    hwpstate, // hardware p-state control
    constant_tsc, // tsc ticks at constant rate
    xop, // the xop instruction set (same as the old cpu_feature_sse5)
    fma3, // the fma3 instruction set
    fma4, // the fma4 instruction set
    tbm, // trailing bit manipulation instruction support
    f16c, // 16-bit fp convert instruction support
    rdrand, // rdrand instruction
    x2apic, // x2apic
    cpb, // core performance boost
    aperfmperf, // mperf/aperf msrs support
    pfi, // processor feedback interface support
    pa, // processor accumulator
    avx2, // avx2 instructions
    bmi1, // bmi1 instructions
    bmi2, // bmi2 instructions
    hle, // hardware lock elision prefixes
    rtm, // restricted transactional memory instructions
    avx512f, // avx-512 foundation
    avx512dq, // avx-512 double/quad granular insns
    avx512pf, // avx-512 prefetch
    avx512er, // avx-512 exponential/reciprocal
    avx512cd, // avx-512 conflict detection
    sha_ni, // sha-1/sha-256 instructions
    avx512bw, // avx-512 byte/word granular insns
    avx512vl, // avx-512 128/256 vector length extensions
    sgx, // sgx extensions. non-autoritative, check cpu_id_t::sgx::present to verify presence
    rdseed, // rdseed instruction
    adx, // adx extensions (arbitrary precision)
    avx512vnni, // avx-512 vector neural network instructions
    avx512vbmi, // avx-512 vector bit manipulationinstructions (version 1)
    avx512vbmi2, // avx-512 vector bit manipulationinstructions (version 2)
};

const FeatureMap = std.EnumMap(Feature, u32);
const FeatureRegisters = enum { ecx_01, edx_01, ebx_07, ecx_80000001, edx_80000001, edx_80000007 };
const BitFeatureMapping = struct { bit: u5, feature: Feature };
const featuresMatchTables = std.EnumMap(FeatureRegisters, []const BitFeatureMapping).init(.{
    .ecx_01 = &.{
        .{ .bit = 0, .feature = .pni },
        .{ .bit = 1, .feature = .pclmul },
        .{ .bit = 3, .feature = .monitor },
        .{ .bit = 9, .feature = .ssse3 },
        .{ .bit = 12, .feature = .fma3 },
        .{ .bit = 13, .feature = .cx16 },
        .{ .bit = 19, .feature = .sse4_1 },
        .{ .bit = 20, .feature = .sse4_2 },
        .{ .bit = 21, .feature = .x2apic },
        .{ .bit = 22, .feature = .movbe },
        .{ .bit = 23, .feature = .popcnt },
        .{ .bit = 25, .feature = .aes },
        .{ .bit = 26, .feature = .xsave },
        .{ .bit = 27, .feature = .osxsave },
        .{ .bit = 28, .feature = .avx },
        .{ .bit = 29, .feature = .f16c },
        .{ .bit = 30, .feature = .rdrand },
    },
    .edx_01 = &.{
        .{ .bit = 0, .feature = .fpu },
        .{ .bit = 1, .feature = .vme },
        .{ .bit = 2, .feature = .de },
        .{ .bit = 3, .feature = .pse },
        .{ .bit = 4, .feature = .tsc },
        .{ .bit = 5, .feature = .msr },
        .{ .bit = 6, .feature = .pae },
        .{ .bit = 7, .feature = .mce },
        .{ .bit = 8, .feature = .cx8 },
        .{ .bit = 9, .feature = .apic },
        .{ .bit = 11, .feature = .sep },
        .{ .bit = 12, .feature = .mtrr },
        .{ .bit = 13, .feature = .pge },
        .{ .bit = 14, .feature = .mca },
        .{ .bit = 15, .feature = .cmov },
        .{ .bit = 16, .feature = .pat },
        .{ .bit = 17, .feature = .pse36 },
        .{ .bit = 19, .feature = .clflush },
        .{ .bit = 23, .feature = .mmx },
        .{ .bit = 24, .feature = .fxsr },
        .{ .bit = 25, .feature = .sse },
        .{ .bit = 26, .feature = .sse2 },
        .{ .bit = 28, .feature = .ht },
    },
    .ebx_07 = &.{
        .{ .bit = 3, .feature = .bmi1 },
        .{ .bit = 5, .feature = .avx2 },
        .{ .bit = 8, .feature = .bmi2 },
        .{ .bit = 18, .feature = .rdseed },
        .{ .bit = 19, .feature = .adx },
        .{ .bit = 29, .feature = .sha_ni },
    },
    .ecx_80000001 = &.{
        .{ .bit = 0, .feature = .lahf_lm },
        .{ .bit = 5, .feature = .abm },
    },
    .edx_80000001 = &.{
        .{ .bit = 11, .feature = .syscall },
        .{ .bit = 27, .feature = .rdtscp },
        .{ .bit = 29, .feature = .lm },
    },
    .edx_80000007 = &.{
        .{ .bit = 8, .feature = .constant_tsc },
    },
});

const CpuidInfoHolder = struct {
    const IntelFunctions = struct {
        fn04: [max_fn04_level]assembly.CpuidResult,
        fn0b: [max_fn0b_level]assembly.CpuidResult,
        fn12: [max_fn12_level]assembly.CpuidResult,
        fn14: [max_fn14_level]assembly.CpuidResult,
    };
    const AmdFunctions = struct {
        fn8000001d: [max_fn8000001d_level]assembly.CpuidResult,
    };

    basic: [max_basic_level]assembly.CpuidResult,
    extended: [max_extended_level]assembly.CpuidResult,
    intel: IntelFunctions,
    amd: AmdFunctions,
};

const CpuVendor = enum {
    unknown,
    intel,
    amd,
};

const MAX_VENDOR_STR = 16;
const MAX_BRAND_STR = 64;
pub const CpuInfo = struct {
    vendor_str: [MAX_VENDOR_STR]u8 = .{0} ** MAX_VENDOR_STR,
    vendor: CpuVendor = .unknown,
    brand_str: [MAX_BRAND_STR]u8 = .{0} ** MAX_BRAND_STR,
    family: u32 = std.math.maxInt(u32),
    model: u32 = std.math.maxInt(u32),
    stepping: u32 = std.math.maxInt(u32),
    extended_family: u32 = std.math.maxInt(u32),
    extended_model: u32 = std.math.maxInt(u32),
    flags: std.EnumSet(Feature) = .initEmpty(),
    // TODO: Add info about TLB/caches/core count
    sse_size: u32 = std.math.maxInt(u32),
};

pub var cpu_info: CpuInfo = .{};

pub fn init() !*CpuInfo {
    var raw_info = std.mem.zeroes(CpuidInfoHolder);
    fillRawInfo(&raw_info);
    try fillCpuInfo(&raw_info, &cpu_info);
    return &cpu_info;
}

pub fn hasFeature(feature: Feature) bool {
    return cpu_info.flags.contains(feature);
}

fn matchFeatures(comptime register: FeatureRegisters, register_value: u32, cpu_identification: *CpuInfo) void {
    const match_table = featuresMatchTables.get(register).?;
    for (match_table) |feature_mapping| {
        cpu_identification.flags.setPresent(feature_mapping.feature, register_value & (@as(u32, 1) << feature_mapping.bit) != 0);
    }
}

fn fillRawInfo(raw_info: *CpuidInfoHolder) void {
    inline for (0..max_basic_level) |i| {
        var cell = &raw_info.basic[i];
        cell.eax = @intCast(i);
        cell.ecx = @intCast(0);
        assembly.cpuid(cell);
    }
    inline for (0..max_extended_level) |i| {
        var cell = &raw_info.extended[i];
        cell.eax = @intCast(0x8000_0000 + i);
        cell.ecx = @intCast(0);
        assembly.cpuid(cell);
    }
    inline for (0..max_fn04_level) |i| {
        var cell = &raw_info.intel.fn04[i];
        cell.eax = @intCast(0x04);
        cell.ecx = @intCast(i);
        assembly.cpuid(cell);
    }
    inline for (0..max_fn0b_level) |i| {
        var cell = &raw_info.intel.fn0b[i];
        cell.eax = @intCast(0x0b);
        cell.ecx = @intCast(i);
        assembly.cpuid(cell);
    }
    inline for (0..max_fn12_level) |i| {
        var cell = &raw_info.intel.fn12[i];
        cell.eax = @intCast(0x12);
        cell.ecx = @intCast(i);
        assembly.cpuid(cell);
    }
    inline for (0..max_fn14_level) |i| {
        var cell = &raw_info.intel.fn14[i];
        cell.eax = @intCast(0x14);
        cell.ecx = @intCast(i);
        assembly.cpuid(cell);
    }
    inline for (0..max_fn8000001d_level) |i| {
        var cell = &raw_info.amd.fn8000001d[i];
        cell.eax = @intCast(0x8000001d);
        cell.ecx = @intCast(i);
        assembly.cpuid(cell);
    }
}

fn fillCpuInfo(raw_info: *const CpuidInfoHolder, cpu_identification: *CpuInfo) !void {
    @memcpy(cpu_identification.vendor_str[0..], @as([*]const u8, @ptrCast(&raw_info.basic[0].ebx)));
    @memcpy(cpu_identification.vendor_str[4..], @as([*]const u8, @ptrCast(&raw_info.basic[0].edx)));
    @memcpy(cpu_identification.vendor_str[8..], @as([*]const u8, @ptrCast(&raw_info.basic[0].ecx)));
    cpu_identification.vendor_str[12] = 0;

    const VendorMatchTableEntry = struct { key: []const u8, value: CpuVendor };
    const vendorMatchTable = [_]VendorMatchTableEntry{
        .{ .key = "AuthenticAMD", .value = .amd },
        .{ .key = "GenuineIntel", .value = .intel },
    };

    cpu_identification.vendor = .unknown;
    for (vendorMatchTable) |entry| {
        if (std.mem.eql(u8, cpu_identification.vendor_str[0..12], entry.key)) {
            cpu_identification.vendor = entry.value;
            break;
        }
    }
    if (cpu_identification.vendor == .unknown)
        return error.UnsupportedCpu;

    const basic = raw_info.basic[0].eax;
    if (basic > 0) {
        cpu_identification.family = (raw_info.basic[1].eax >> 8) & 0xf;
        cpu_identification.model = (raw_info.basic[1].eax >> 4) & 0xf;
        cpu_identification.stepping = raw_info.basic[1].eax & 0xf;
        const extended_model = (raw_info.basic[1].eax >> 16) & 0xf;
        const extended_family = (raw_info.basic[1].eax >> 20) & 0xff;
        if (cpu_identification.vendor == .amd and cpu_identification.family < 0xf) {
            cpu_identification.extended_family = cpu_identification.family;
        } else {
            cpu_identification.extended_family = cpu_identification.family + extended_family;
        }
        cpu_identification.extended_model = cpu_identification.model + (extended_model << 4);
    }

    if (raw_info.extended[0].eax >= 0x8000_0004) {
        for (2..5) |offset| {
            const leaf = raw_info.extended[offset];
            @memcpy(cpu_identification.brand_str[(0 + (offset - 2) * 16)..], @as([*]const u8, @ptrCast(&leaf.eax)));
            @memcpy(cpu_identification.brand_str[(4 + (offset - 2) * 16)..], @as([*]const u8, @ptrCast(&leaf.ebx)));
            @memcpy(cpu_identification.brand_str[(8 + (offset - 2) * 16)..], @as([*]const u8, @ptrCast(&leaf.ecx)));
            @memcpy(cpu_identification.brand_str[(12 + (offset - 2) * 16)..], @as([*]const u8, @ptrCast(&leaf.edx)));
        }
        cpu_identification.brand_str[48] = 0;
    }

    if (raw_info.basic[0].eax > 0) {
        matchFeatures(.ecx_01, raw_info.basic[1].ecx, cpu_identification);
        matchFeatures(.edx_01, raw_info.basic[1].edx, cpu_identification);
    }
    if (raw_info.basic[0].eax > 6) {
        matchFeatures(.ebx_07, raw_info.basic[7].ebx, cpu_identification);
    }
    if (raw_info.basic[0].eax > 0x80000001) {
        matchFeatures(.ecx_80000001, raw_info.extended[1].ecx, cpu_identification);
        matchFeatures(.edx_80000001, raw_info.extended[1].edx, cpu_identification);
    }
    if (raw_info.basic[0].eax > 0x80000007) {
        matchFeatures(.edx_80000007, raw_info.extended[7].edx, cpu_identification);
    }

    if (cpu_identification.flags.contains(.sse)) {
        switch (cpu_identification.vendor) {
            .intel => {
                cpu_identification.sse_size = if (cpu_identification.family == 6 and cpu_identification.extended_model >= 15) 128 else 64;
            },
            .amd => {
                cpu_identification.sse_size = if (cpu_identification.extended_family >= 16 and cpu_identification.extended_family != 17) 128 else 64;
            },
            else => {},
        }
    }
}

pub const CpuContext = struct {
    pub const Gpr = enum {
        // zig fmt: off
        rax, rdx, rcx, rbx,
        rsi, rdi, rbp, rsp,
        r8,  r9,  r10, r11,
        r12, r13, r14, r15,
        rip,
        // zig fmt: on
    };
    gprs: std.enums.EnumArray(Gpr, u64),

    pub inline fn current() CpuContext {
        var ctx: CpuContext = undefined;
        asm volatile (
            \\movq %%rax, 0x00(%%rdi)
            \\movq %%rdx, 0x08(%%rdi)
            \\movq %%rcx, 0x10(%%rdi)
            \\movq %%rbx, 0x18(%%rdi)
            \\movq %%rsi, 0x20(%%rdi)
            \\movq %%rdi, 0x28(%%rdi)
            \\movq %%rbp, 0x30(%%rdi)
            \\movq %%rsp, 0x38(%%rdi)
            \\movq %%r8,  0x40(%%rdi)
            \\movq %%r9,  0x48(%%rdi)
            \\movq %%r10, 0x50(%%rdi)
            \\movq %%r11, 0x58(%%rdi)
            \\movq %%r12, 0x60(%%rdi)
            \\movq %%r13, 0x68(%%rdi)
            \\movq %%r14, 0x70(%%rdi)
            \\movq %%r15, 0x78(%%rdi)
            \\leaq (%%rip), %%rax
            \\movq %%rax, 0x80(%%rdi)
            \\movq 0x00(%%rdi), %%rax
            :
            : [gprs] "{rdi}" (&ctx.gprs.values),
            : .{ .memory = true });
        return ctx;
    }

    pub fn getFp(ctx: *const CpuContext) usize {
        return @intCast(ctx.gprs.get(.rbp));
    }
    pub fn getPc(ctx: *const CpuContext) usize {
        return @intCast(ctx.gprs.get(.rip));
    }

    pub fn dwarfRegisterBytes(ctx: *CpuContext, register_num: u16) std.debug.cpu_context.DwarfRegisterError![]u8 {
        // System V Application Binary Interface AMD64 Architecture Processor Supplement
        //   § 3.6.2 "DWARF Register Number Mapping"
        switch (register_num) {
            // The order of `Gpr` intentionally matches DWARF's mappings.
            0...16 => return @ptrCast(&ctx.gprs.values[register_num]),

            17...32 => return error.UnsupportedRegister, // xmm0 - xmm15
            33...40 => return error.UnsupportedRegister, // st0 - st7
            41...48 => return error.UnsupportedRegister, // mm0 - mm7
            49 => return error.UnsupportedRegister, // rflags
            50...55 => return error.UnsupportedRegister, // es, cs, ss, ds, fs, gs
            58...59 => return error.UnsupportedRegister, // fs.base, gs.base
            62 => return error.UnsupportedRegister, // tr
            63 => return error.UnsupportedRegister, // ldtr
            64 => return error.UnsupportedRegister, // mxcsr
            65 => return error.UnsupportedRegister, // fcw
            66 => return error.UnsupportedRegister, // fsw
            67...82 => return error.UnsupportedRegister, // xmm16 - xmm31 (AVX-512)
            118...125 => return error.UnsupportedRegister, // k0 - k7 (AVX-512)
            130...145 => return error.UnsupportedRegister, // r16 - r31 (APX)

            else => return error.InvalidRegister,
        }
    }
};

pub const MSR = enum(u32) {
    MTRRCAP = 0x000000FE,
    MTRR_PHYSBASE0 = 0x00000200,
    MTRR_PHYSBASE1 = 0x00000202,
    MTRR_PHYSBASE2 = 0x00000204,
    MTRR_PHYSBASE3 = 0x00000206,
    MTRR_PHYSBASE4 = 0x00000208,
    MTRR_PHYSBASE5 = 0x0000020a,
    MTRR_PHYSBASE6 = 0x0000020c,
    MTRR_PHYSBASE7 = 0x0000020e,
    MTRR_PHYSBASE8 = 0x00000210,
    MTRR_PHYSBASE9 = 0x00000212,
    MTRR_PHYSMASK0 = 0x00000201,
    MTRR_PHYSMASK1 = 0x00000203,
    MTRR_PHYSMASK2 = 0x00000205,
    MTRR_PHYSMASK3 = 0x00000207,
    MTRR_PHYSMASK4 = 0x00000209,
    MTRR_PHYSMASK5 = 0x0000020b,
    MTRR_PHYSMASK6 = 0x0000020d,
    MTRR_PHYSMASK7 = 0x0000020f,
    MTRR_PHYSMASK8 = 0x00000211,
    MTRR_PHYSMASK9 = 0x00000213,
    MTRRdefType = 0x000002FF,
    MTRRfix16K_80000 = 0x00000258,
    MTRRfix16K_A0000 = 0x00000259,
    MTRRfix4K_C0000 = 0x00000268,
    MTRRfix4K_C8000 = 0x00000269,
    MTRRfix4K_D0000 = 0x0000026a,
    MTRRfix4K_D8000 = 0x0000026b,
    MTRRfix4K_E0000 = 0x0000026c,
    MTRRfix4K_E8000 = 0x0000026d,
    MTRRfix4K_F0000 = 0x0000026e,
    MTRRfix4K_F8000 = 0x0000026f,
    MTRRfix64K_00000 = 0x00000250,
    PAT = 0x00000277,
    APIC_BASE = 0x0000001b,
    X2APIC_APICID = 0x00000802,
    X2APIC_VERSION = 0x00000803,
    X2APIC_TPR = 0x00000808,
    X2APIC_PPR = 0x0000080a,
    X2APIC_EOI = 0x0000080b,
    X2APIC_LDR = 0x0000080d,
    X2APIC_SIVR = 0x0000080f,
    X2APIC_ISR0 = 0x00000810,
    X2APIC_ISR1 = 0x00000811,
    X2APIC_ISR2 = 0x00000812,
    X2APIC_ISR3 = 0x00000813,
    X2APIC_ISR4 = 0x00000814,
    X2APIC_ISR5 = 0x00000815,
    X2APIC_ISR6 = 0x00000816,
    X2APIC_ISR7 = 0x00000817,
    X2APIC_TMR0 = 0x00000818,
    X2APIC_TMR1 = 0x00000819,
    X2APIC_TMR2 = 0x0000081a,
    X2APIC_TMR3 = 0x0000081b,
    X2APIC_TMR4 = 0x0000081c,
    X2APIC_TMR5 = 0x0000081d,
    X2APIC_TMR6 = 0x0000081e,
    X2APIC_TMR7 = 0x0000081f,
    X2APIC_IRR0 = 0x00000820,
    X2APIC_IRR1 = 0x00000821,
    X2APIC_IRR2 = 0x00000822,
    X2APIC_IRR3 = 0x00000823,
    X2APIC_IRR4 = 0x00000824,
    X2APIC_IRR5 = 0x00000825,
    X2APIC_IRR6 = 0x00000826,
    X2APIC_IRR7 = 0x00000827,
    X2APIC_ESR = 0x00000828,
    X2APIC_CMCI = 0x0000082f,
    X2APIC_ICR = 0x00000830,
    X2APIC_LVT_TIMER = 0x00000832,
    X2APIC_LVT_THERMAL = 0x00000833,
    X2APIC_LVT_PMC = 0x00000834,
    X2APIC_LVT_LINT0 = 0x00000835,
    X2APIC_LVT_LINT1 = 0x00000836,
    X2APIC_LVT_ERROR = 0x00000837,
    X2APIC_INIT_COUNT = 0x00000838,
    X2APIC_CUR_COUNT = 0x00000839,
    X2APIC_DIV_CONFIG = 0x0000083e,
    X2APIC_SELF_IPI = 0x0000083f,
};
