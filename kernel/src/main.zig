const std = @import("std");
const constants = @import("constants");
const BootInfo = @import("bootinfo.zig").BootInfo;
const logger = @import("log/logger.zig");
const cpu = @import("cpu.zig");
const serial = @import("log/serial.zig");
const mem = @import("memory.zig");
const descriptors = @import("descriptors.zig");
const debug = @import("debug.zig");
const arch = @import("arch");
const Memory = @import("memory.zig");
const panicFn = @import("panic.zig").panicFn;

pub const panic = std.debug.FullPanic(panicFn);

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
    .page_size_min = arch.constants.default_page_size,
    .page_size_max = arch.constants.default_page_size,
};

// comptime {
//     if (constants.max_cpu <= 0) @compileError("No max_cpu set");
// }

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ .global kernelMain
        \\ mov $0, %rbp
        \\ mov %rbp, %rsp
        \\ call kernelMain
    );
    while (true) {}
}

pub export fn kernelMain() callconv(.c) void {
    logger.init(serial.Port.COM1);
    cpu.init() catch unreachable;
    std.log.info("Cpu vendor id: {s}", .{cpu.cpu_info.vendor_str[0..12]});

    failableMain() catch |e| {
        std.log.err("Failed with error: {any}", .{e});
    };
}

pub fn failableMain() !void {
    try Memory.earlyInit();
    const kernel_alloc = Memory.allocator();

    const allocated = try kernel_alloc.alloc(u64, 10);
    defer kernel_alloc.free(allocated);
    allocated[0] = 42;
    for (0.., allocated) |i, a| {
        std.log.info("allocated[{d}] = {d}", .{ i, a });
    }

    try Memory.init();

    std.log.info("Quick mapping", .{});
    const addr = Memory.kernel_vmem.quickMap(0x1400000);
    const v_id_mapped: *u64 = @ptrFromInt(0x1400000);
    v_id_mapped.* = 456;
    const v: *u64 = @ptrFromInt(addr);
    v.* = 123;
    std.log.info("quick mapped value @ {*} {d} {d}", .{ v, v.*, v_id_mapped.* });
    Memory.kernel_vmem.quickUnmap();

    v_id_mapped.* = 654;
    std.log.info("value @ {d}", .{v_id_mapped.*});

    // v.* = 321;
    // std.log.info("value @ {*} {d} {d}", .{ v, v.*, v_id_mapped.* });
    std.log.info("cpu has feature sse2 {any}", .{cpu.hasFeature(.sse2)});

    descriptors.init();

    try Memory.lateInit();
    try debug.init(kernel_alloc);

    // v.* = 321;
    // std.log.info("value @ {*} {d} {d}", .{ v, v.*, v_id_mapped.* });
    @panic("test");
}
