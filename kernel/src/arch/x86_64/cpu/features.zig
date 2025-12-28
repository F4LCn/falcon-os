const std = @import("std");
const assembly = @import("../assembly.zig");

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

pub const FeatureMap = std.EnumMap(Feature, u32);
pub const FeatureRegisters = enum { ecx_01, edx_01, ebx_07, ecx_80000001, edx_80000001, edx_80000007 };
pub const BitFeatureMapping = struct { bit: u5, feature: Feature };
pub const featuresMatchTables = std.EnumMap(FeatureRegisters, []const BitFeatureMapping).init(.{
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

pub fn matchFeatures(comptime register: FeatureRegisters, register_value: u32, cpu_identification: *CpuInfo) void {
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
    base_freq: u32 = std.math.maxInt(u32),
    tsc_freq: u32 = std.math.maxInt(u32),
    // TODO: Add info about TLB/caches/core count
    sse_size: u32 = std.math.maxInt(u32),
};

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

    if (raw_info.basic[0].eax >= 1) {
        matchFeatures(.ecx_01, raw_info.basic[1].ecx, cpu_identification);
        matchFeatures(.edx_01, raw_info.basic[1].edx, cpu_identification);
    }
    if (raw_info.basic[0].eax >= 7) {
        matchFeatures(.ebx_07, raw_info.basic[7].ebx, cpu_identification);
    }
    if (raw_info.basic[0].eax >= 0x80000001) {
        matchFeatures(.ecx_80000001, raw_info.extended[1].ecx, cpu_identification);
        matchFeatures(.edx_80000001, raw_info.extended[1].edx, cpu_identification);
    }
    if (raw_info.basic[0].eax >= 0x80000007) {
        matchFeatures(.edx_80000007, raw_info.extended[7].edx, cpu_identification);
    }
    if (raw_info.basic[0].eax >= 22) {
        cpu_identification.base_freq = (raw_info.basic[22].eax & 0xffff) * 1_000_000;
        cpu_identification.tsc_freq = cpu_identification.base_freq;
    }
    if (raw_info.basic[0].eax >= 21) {
        cpu_identification.base_freq = raw_info.basic[21].ecx & 0xffff;
        const numerator = raw_info.basic[21].ebx;
        const denominator = raw_info.basic[21].eax;
        cpu_identification.tsc_freq = cpu_identification.base_freq * numerator / denominator;
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

pub fn init(cpu_info: *CpuInfo) !void {
    var raw_info = std.mem.zeroes(CpuidInfoHolder);
    fillRawInfo(&raw_info);
    try fillCpuInfo(&raw_info, cpu_info);
}
