const std = @import("std");
const arch = @import("arch");
const assembly = arch.assembly;

const log = std.log.scoped(.pit);
pub const Self = @This();

pub const frequency: u64 = 1193182;
pub const commandPort: u8 = 0x43;

pub const Channels = enum(u2) {
    Channel0 = 0,
    Channel1 = 1,
    Channel2 = 2,
    Invalid = 3,
};

pub const Ports = enum(u8) {
    Channel0 = 0x40,
    Channel1 = 0x41,
    Channel2 = 0x42,

    pub fn fromChannel(channel: Channels) Ports {
        return switch (channel) {
            .Channel0 => .Channel0,
            .Channel1 => .Channel1,
            .Channel2 => .Channel2,
            else => @panic("Invalid PIT channel"),
        };
    }
};

pub const Command = packed struct(u8) {
    binaryBcd: enum(u1) {
        binary = 0,
        bcd = 1,
    } = .binary,
    operatingMode: enum(u3) {
        interrupt_on_terminal_count = 0,
        hardware_retriggerable_oneshot = 1,
        rate_gen = 2,
        square_wave_gen = 3,
        software_strobe = 4,
        hardware_strobe = 5,
        rate_gen_2 = 6,
        square_wave_gen_2 = 7,
    } = .interrupt_on_terminal_count,
    accessMode: enum(u2) {
        latch = 0,
        lobyte = 1,
        hibyte = 2,
        lohibyte = 3,
    } = .lohibyte,
    channel: enum(u2) {
        channel0 = 0,
        channel1 = 1,
        channel2 = 2,
        readback = 3,
    },
};

pub fn init() void {}

pub fn millis(ms: u16) u16 {
    const count = @as(u64, @intCast(ms)) * frequency / 1_000;
    log.debug("{d}ms = {d} ticks", .{ ms, count });
    return @intCast(count);
}

pub fn micros(us: u16) u16 {
    return @intCast(us * frequency / 1_000_000);
}

pub const pit = Self.init();

pub fn setCounter(channel: Channels, count: u16) void {
    const port = Ports.fromChannel(channel);
    assembly.outb(commandPort, @bitCast(Command{
        .channel = @enumFromInt(@intFromEnum(channel)),
    }));
    assembly.outb(@intFromEnum(port), @intCast(count & 0xFF));
    assembly.outb(@intFromEnum(port), @intCast((count & 0xFF00) >> 8));
}

pub fn getCount(channel: Channels) u16 {
    const port = Ports.fromChannel(channel);
    assembly.outb(commandPort, @bitCast(Command{
        .accessMode = .latch,
        .channel = @enumFromInt(@intFromEnum(channel)),
    }));
    const lobyte = assembly.inb(@intFromEnum(port));
    const hibyte = assembly.inb(@intFromEnum(port));
    return @as(u16, @intCast(lobyte)) | (@as(u16, @intCast(hibyte)) << 8);
}

pub fn wait(count: u16) void {
    var last_count = count;
    setCounter(.Channel0, count);
    while (last_count > 0) {
        const current_count = getCount(.Channel0);
        if (current_count > last_count) break;
        last_count = current_count;
    }
}
