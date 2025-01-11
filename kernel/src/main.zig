const std = @import("std");
const BootInfo = @import("bootinfo.zig").BootInfo;
const logger = @import("log/logger.zig");
const cpu = @import("cpu.zig");
const serial = @import("log/serial.zig");

extern var bootinfo: *const BootInfo;

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ .extern kernelMain
        \\ call kernelMain
    );

    while (true) {}
}

pub export fn kernelMain() callconv(.c) void {
    cpu.init();
    std.log.info("Cpu vendor id: {s}", .{cpu.cpu_info.vendor_str});
}
