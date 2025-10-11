const std = @import("std");
const options = @import("options");
const logger = @import("log/logger.zig");
const cpu = @import("cpu.zig");
const serial = @import("log/serial.zig");
const mem = @import("memory.zig");
const descriptors = @import("descriptors.zig");
const arch = @import("arch");
const flcn = @import("flcn");
pub const debug = flcn.debug;
const BootInfo = flcn.bootinfo.BootInfo;
const Memory = @import("memory.zig");
const panicFn = @import("panic.zig").panicFn;

pub const panic = std.debug.FullPanic(panicFn);

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
    .page_size_min = arch.constants.default_page_size,
    .page_size_max = arch.constants.default_page_size,
};

comptime {
    if (options.max_cpu <= 0) @compileError("No max_cpu set");
}

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
    const addr = Memory.kernel_vmem.physToVirt(0x1400000);
    // const v_id_mapped: *u64 = @ptrFromInt(0x1400000);
    // v_id_mapped.* = 456;
    const v: *u64 = @ptrFromInt(addr.toAddr());
    v.* = 123;
    std.log.info("quick mapped value @ {*} {d}", .{ v, v.* });

    std.log.info("cpu has feature sse2 {any}", .{cpu.hasFeature(.sse2)});
    try debug.init(Memory.permanent_allocator);
    descriptors.init();
    // try Memory.lateInit();
    Memory.printStats();

    
    // std.log.info("page allocator test", .{});
    // const page_alloc = Memory.pageAllocator();
    // Memory.kernel_vmem.printRanges();
    // const allocated2 = try page_alloc.alloc([arch.constants.default_page_size]u8, 1000);
    // defer page_alloc.free(allocated2);
    // std.log.info("allocated pages at 0x{x} with length {x}", .{ @intFromPtr(allocated2.ptr), allocated2.len });

    // v.* = 321;
    // std.log.info("value @ {*} {d} {d}", .{ v, v.*, v_id_mapped.* });
    @panic("test");
}
