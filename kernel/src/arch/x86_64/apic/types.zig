const std = @import("std");
const cpu = @import("../cpu.zig");

pub const IPIMessageType = enum(u3) {
    fixed = 0b00,
    lowest_priority = 0b001,
    smi = 0b010,
    nmi = 0b100,
    init = 0b101,
    startup = 0b110,
};

pub const IPIMessage = union(IPIMessageType) {
    fixed: struct { vector: u8 },
    lowest_priority: struct { vector: u8 },
    smi,
    nmi,
    init,
    startup: struct { trampoline: std.math.IntFittingRange(0, 0xfffff) },
};

pub const IPIDestination = union(enum(u2)) {
    apic: struct { id: cpu.CpuId } = 0b00,
    self = 0b01,
    all = 0b10,
    all_excluding_self = 0b11,
};

pub const SendIPIOptions = struct {
    wait_for_send: bool = false,
};
