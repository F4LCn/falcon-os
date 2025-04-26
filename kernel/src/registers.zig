const Register = enum {
    cr2,
    cr3,
    cr4,
};

pub fn readCR(comptime reg: Register) u64 {
    const reg_name = @tagName(reg);
    const read_instr = "mov %" ++ reg_name ++ ", %[page_map]";
    return asm (read_instr
        : [page_map] "={r8}" (-> u64),
        :
        : "r8"
    );
}
