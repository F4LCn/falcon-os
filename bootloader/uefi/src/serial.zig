const std = @import("std");
const io = @import("io.zig");

pub const Port = enum(u16) {
    COM1 = 0x3F8,
    COM2 = 0x2F8,
    COM3 = 0x3E8,
    COM4 = 0x2E8,
    COM5 = 0x5F8,
    COM6 = 0x4F8,
    COM7 = 0x5E8,
    COM8 = 0x4E8,
};

pub const Offset = enum(u8) {
    RxTxBuffer = 0, // if dlab set => divisor LSB
    IntEnable = 1, // if dlab set => divisor MSB
    FifoCtrl = 2,
    LineCtrl = 3,
    ModemCtrl = 4,
    LineStatus = 5,
    ModemStatus = 6,
    Scratch = 7,
};

const LineCtrlReg = packed struct(u8) {
    data: u2 = 0,
    stop: u1 = 0,
    parity: u3 = 0,
    break_enable: u1 = 0,
    dlab: u1 = 0,
};

const FifoCtrlReg = packed struct(u8) {
    enable: bool = false,
    clear_rx: bool = false,
    clear_tx: bool = false,
    dma_mode: u1 = 0,
    rsrvd: u2 = undefined,
    int_trigger: u2 = 0,
};

const ModemCtrlReg = packed struct(u8) {
    dtr: u1 = 1,
    rts: u1 = 1,
    out1: u1 = 1,
    out2: u1 = 1,
    loop: bool = false,
    rsrvd: u3 = undefined,
};

pub const SerialWriter = struct {
    port: Port,
    writer: std.Io.Writer,
    pub const SerialError = error{};
    const Self = @This();
    pub fn init(comptime port: Port) SerialWriter {
        const port_num = @intFromEnum(port);
        io.outb(port_num + @intFromEnum(Offset.IntEnable), 0);
        io.outb(port_num + @intFromEnum(Offset.LineCtrl), @bitCast(LineCtrlReg{ .dlab = 1 }));
        io.outb(port_num + @intFromEnum(Offset.RxTxBuffer), 3);
        io.outb(port_num + @intFromEnum(Offset.IntEnable), 0);
        io.outb(port_num + @intFromEnum(Offset.LineCtrl), @bitCast(LineCtrlReg{ .data = 3 }));
        io.outb(port_num + @intFromEnum(Offset.FifoCtrl), @bitCast(FifoCtrlReg{ .enable = true, .clear_rx = true, .clear_tx = true, .int_trigger = 0b11 }));
        io.outb(port_num + @intFromEnum(Offset.ModemCtrl), @bitCast(ModemCtrlReg{ .out1 = 0, .loop = true }));
        io.outb(port_num + @intFromEnum(Offset.RxTxBuffer), 0xAA);

        if (io.inb(port_num) != 0xAA) {
            unreachable;
        }

        io.outb(port_num + @intFromEnum(Offset.ModemCtrl), @bitCast(ModemCtrlReg{}));

        return .{
            .port = port,
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = &[0]u8{},
            },
        };
    }

    pub fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        _ = splat;
        const self: *SerialWriter = @fieldParentPtr("writer", w);
        var out: usize = 0;
        for (data) |datum|
            out += try self.write(datum);
        return out;
    }

    fn write(self: *const Self, bytes: []const u8) SerialError!usize {
        const port = self.port;
        const port_num = @intFromEnum(port);
        for (bytes) |b| {
            while ((io.inb(port_num + @intFromEnum(Offset.LineStatus)) & 0x20) == 0) {
                continue;
            }
            io.outb(port_num, b);
        }
        return bytes.len;
    }
};
