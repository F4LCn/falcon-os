const registers = @import("registers.zig");
const cpu = @import("cpu.zig");
pub const ISR = *const fn () callconv(.naked) void;

pub const InterruptContext = extern struct {
    registers: registers.Registers align(1),
    vector: u64 align(1),
    error_code: u64 align(1),
    rip: u64 align(1),
    cs: u64 align(1),
    flags: u64 align(1),
};

pub fn toCpuContext(self: *const InterruptContext) cpu.CpuContext {
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
// more like arch specific
pub fn genVectorISR(vector: comptime_int) ISR {
    return struct {
        pub fn handler() callconv(.naked) void {
            asm volatile ("cli");
            switch (vector) {
                8, 10...14, 17, 21 => {},
                else => {
                    asm volatile ("pushq $0");
                },
            }
            asm volatile ("pushq %[v]"
                :
                : [v] "n" (vector),
            );
            asm volatile ("jmp commonISR");
        }
    }.handler;
}

export fn commonISR() callconv(.naked) void {
    asm volatile (
        \\ pushq %%rax
        \\ pushq %%rbx
        \\ pushq %%rcx
        \\ pushq %%rdx
        \\ pushq %%rsi
        \\ pushq %%rdi
        \\ pushq %%rsp
        \\ pushq %%rbp
        \\ pushq %%r8
        \\ pushq %%r9
        \\ pushq %%r10
        \\ pushq %%r11
        \\ pushq %%r12
        \\ pushq %%r13
        \\ pushq %%r14
        \\ pushq %%r15
        \\ pushq %%rsp
        \\ popq %%rdi
        \\ pushq %%rsp
        \\ pushq (%%rsp)
        \\ andq $-0x10, %%rsp
        \\ call dispatchInterrupt
        \\ mov 8(%%rsp), %%rsp
        \\ popq %%r15
        \\ popq %%r14
        \\ popq %%r13
        \\ popq %%r12
        \\ popq %%r11
        \\ popq %%r10
        \\ popq %%r9
        \\ popq %%r8
        \\ popq %%rbp
        \\ popq %%rsp
        \\ popq %%rdi
        \\ popq %%rsi
        \\ popq %%rdx
        \\ popq %%rcx
        \\ popq %%rbx
        \\ popq %%rax
        \\ addq $0x10, %%rsp
        \\ iretq
    );
}
