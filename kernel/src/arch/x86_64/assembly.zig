const std = @import("std");
const memory = @import("memory.zig");
const cpu = @import("cpu.zig");

pub const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub inline fn cpuid(regs: *CpuidResult) void {
    var eax: u32 = regs.eax;
    var ebx: u32 = regs.ebx;
    var ecx: u32 = regs.ecx;
    var edx: u32 = regs.edx;

    asm volatile (
        \\ cpuid
        : [out_a] "={eax}" (eax),
          [out_b] "={ebx}" (ebx),
          [out_c] "={ecx}" (ecx),
          [out_d] "={edx}" (edx),
        : [in_a] "{eax}" (eax),
          [in_c] "{ecx}" (ecx),
    );

    regs.eax = eax;
    regs.ebx = ebx;
    regs.ecx = ecx;
    regs.edx = edx;
}

pub inline fn rdmsr(msr: cpu.MSR) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile (
        \\ rdmsr
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (@intFromEnum(msr)),
    );
    return (@as(u64, @intCast(high)) << 32) | (@as(u64, @intCast(low)));
}

pub inline fn wrmsr(msr: cpu.MSR, val: u64) void {
    asm volatile (
        \\ wrmsr
        :
        : [msr] "{ecx}" (@intFromEnum(msr)),
          [val_upper] "{edx}" (val >> 32),
          [val_lower] "{eax}" (val & std.math.maxInt(u32)),
    );
}

pub inline fn halt() void {
    asm volatile ("hlt");
}

pub inline fn haltEternally() noreturn {
    while (true) asm volatile ("hlt");
}

pub inline fn spinLoopHint() void {
    asm volatile ("pause");
}

pub inline fn invalidateVirtualAddress(addr: memory.VAddrSize) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
        : .{ .memory = true });
}

pub inline fn outb(port: u16, value: u8) void {
    return asm volatile (
        \\ outb %[value], %[port]
        :
        : [port] "{dx}" (port),
          [value] "{al}" (value),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile (
        \\ inb %[port], %[value]
        : [value] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub inline fn outString(port: u16, bytes: []const u8) u64 {
    const unwritten_bytes = asm volatile (
        \\ rep outsb
        : [ret] "={rcx}" (-> u64),
        : [port] "{dx}" (port),
          [src] "{rsi}" (bytes.ptr),
          [len] "{rcx}" (bytes.len),
        : .{ .rcx = true, .rsi = true });
    return bytes.len - unwritten_bytes;
}

pub inline fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile (
        \\ rdtsc
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, @intCast(high)) << 32) | (@as(u64, @intCast(low)));
}
