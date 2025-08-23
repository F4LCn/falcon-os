const constants = @import("constants");

pub const ISR = *const fn () callconv(.naked) void;

pub const Registers = switch (constants.arch) {
    .x86_64 => @import("../arch/x64/registers.zig").Regs,
    else => @compileError("Unsupported arch " ++ @tagName(constants.arch)),
};

pub const Context = packed struct {
    registers: Registers,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    flags: u64,
};
