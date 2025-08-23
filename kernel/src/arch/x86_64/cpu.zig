const std = @import("std");
const assembly = @import("asm.zig");

const CpuidInfoHolder = struct {
    basic: [32]assembly.CpuidResult,
    extended: [32]assembly.CpuidResult,
};

const CpuVendor = enum {
    unknown,
    intel,
    amd,
};

pub const CpuFlags = struct {
    sse: bool,
    sse2: bool,
    sse3: bool,
    sse41: bool,
    sse42: bool,
    avx: bool,
    avx2: bool,
};

const MAX_VENDOR_STR = 16;
const MAX_BRAND_STR = 64;
pub const CpuInfo = struct {
    vendor_str: [MAX_VENDOR_STR]u8 = .{0} ** MAX_VENDOR_STR,
    vendor: CpuVendor = .unknown,
    brand_str: [MAX_BRAND_STR]u8 = .{0} ** MAX_BRAND_STR,
    flags: CpuFlags = std.mem.zeroes(CpuFlags),
    // TODO: Add info about TLB/caches/core count
};

pub var cpu_info: CpuInfo = .{};

pub fn init() void {
    var raw_info = std.mem.zeroes(CpuidInfoHolder);
    fillRawInfo(&raw_info);
    fillCpuInfo(&raw_info, &cpu_info);
}

fn fillRawInfo(raw_info: *CpuidInfoHolder) void {
    for (0..32) |i| {
        var cell = &raw_info.basic[i];
        cell.eax = @intCast(i);
        cell.ecx = @intCast(0);
        assembly.cpuid(cell);
    }
    for (0..32) |i| {
        var cell = &raw_info.extended[i];
        cell.eax = @intCast(0x8000_0000 + i);
        cell.ecx = @intCast(0);
        assembly.cpuid(cell);
    }
}

fn fillCpuInfo(raw_info: *const CpuidInfoHolder, cpu_identification: *CpuInfo) void {
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
}
