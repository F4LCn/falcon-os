const std = @import("std");
const cpu = @import("../cpu.zig");

pub const IPI = packed struct(u32) {
    vector: u8,
    delivery_mode: u3,
    destination_mode: u1 = 0,
    delivery_status: u1 = 0,
    _reserved0: u1 = 0,
    level: u1 = 1,
    trigger_mode: u1 = 0,
    _reserved1: u2 = 0,
    destination_shorthand: u2,
    _reserved2: u12 = 0,

    pub fn formatNumber(self: IPI, writer: *std.Io.Writer, _: std.fmt.Number) !void {
        try writer.print("{x}", .{@as(u32, @bitCast(self))});
    }
};

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
    startup: struct { trampoline: u16 },
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
