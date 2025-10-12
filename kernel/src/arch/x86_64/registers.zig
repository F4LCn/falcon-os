pub const Registers = extern struct {
    r15: u64 align(1),
    r14: u64 align(1),
    r13: u64 align(1),
    r12: u64 align(1),
    r11: u64 align(1),
    r10: u64 align(1),
    r9: u64 align(1),
    r8: u64 align(1),
    rbp: u64 align(1),
    rsp: u64 align(1),
    rdi: u64 align(1),
    rsi: u64 align(1),
    rdx: u64 align(1),
    rcx: u64 align(1),
    rbx: u64 align(1),
    rax: u64 align(1),
};

const ControlRegisters = enum {
    cr2,
    cr3,
    cr4,
};

pub fn readCR(comptime reg: ControlRegisters) u64 {
    const reg_name = @tagName(reg);
    const read_instr = "mov %" ++ reg_name ++ ", %[page_map]";
    return asm (read_instr
        : [page_map] "={r8}" (-> u64),
        :
        : .{ .r8 = true });
}
