const std = @import("std");

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
