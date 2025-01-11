const std = @import("std");

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
