const options = @import("options");
const arch = @import("arch");
pub const ISR = *const fn () callconv(.naked) void;


pub const Context = packed struct {
    registers: arch.registers.Registers,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    flags: u64,
};
