const std = @import("std");
const options = @import("options");
const arch = @import("arch");
pub const ISR = *const fn () callconv(.naked) void;

pub const InterruptContext = extern struct {
    registers: arch.registers.Registers align(1),
    vector: u64 align(1),
    error_code: u64 align(1),
    rip: u64 align(1),
    cs: u64 align(1),
    flags: u64 align(1),
};

pub fn toCpuContext(self: *const InterruptContext) arch.cpu.CpuContext {
    return .{
        .gprs = .init(.{
            .r15 = self.registers.r15,
            .r14 = self.registers.r14,
            .r13 = self.registers.r13,
            .r12 = self.registers.r12,
            .r11 = self.registers.r11,
            .r10 = self.registers.r10,
            .r9 = self.registers.r9,
            .r8 = self.registers.r8,
            .rbp = self.registers.rbp,
            .rsp = self.registers.rsp,
            .rdi = self.registers.rdi,
            .rsi = self.registers.rsi,
            .rdx = self.registers.rdx,
            .rcx = self.registers.rcx,
            .rbx = self.registers.rbx,
            .rax = self.registers.rax,
            .rip = self.rip,
        }),
    };
}
