const memory = @import("memory.zig");

pub const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub fn cpuid(regs: *CpuidResult) void {
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

pub fn halt() void {
    asm volatile ("hlt");
}

pub fn haltEternally() noreturn {
    while (true) asm volatile ("hlt");
}

pub fn invalidateVirtualAddress(addr: memory.VAddrSize) void {
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

pub inline fn outString(port: u16, bytes: []const u8) usize {
    const unwritten_bytes = asm volatile (
        \\ rep outsb
        : [ret] "={rcx}" (-> usize),
        : [port] "{dx}" (port),
          [src] "{rsi}" (bytes.ptr),
          [len] "{rcx}" (bytes.len),
        : .{ .rcx = true, .rsi = true }
    );
    return bytes.len - unwritten_bytes;
}
