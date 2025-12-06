const std = @import("std");
const options = @import("options");
const logger = @import("log/logger.zig");
const cpu = @import("cpu.zig");
const serial = @import("log/serial.zig");
const mem = @import("memory.zig");
const descriptors = @import("descriptors.zig");
const arch = @import("arch");
const flcn = @import("flcn");
pub const debug = @import("debug.zig");
const BootInfo = flcn.bootinfo.BootInfo;
const Memory = @import("memory.zig");
const acpi = @import("acpi.zig");
const smp = @import("smp.zig");
const PIT = @import("pit.zig");
const panicFn = @import("panic.zig").panicFn;

pub const panic = std.debug.FullPanic(panicFn);

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .debug, .level = .info },
        .{ .scope = .@"x86_64.memory", .level = .info },
    },
    .page_size_min = arch.constants.default_page_size,
    .page_size_max = arch.constants.default_page_size,
};

comptime {
    if (options.max_cpu <= 0) @compileError("No max_cpu set");
}

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ .global kernelMain
        // Are we an AP ?
        // set up the AP stack
        // jump to AP specific startup code
        \\ mov $0, %rbp
        \\ mov %rbp, %rsp
        \\ call kernelMain
    );
    while (true) {}
}

pub export fn kernelMain() callconv(.c) void {
    logger.init(serial.Port.COM1);
    cpu.earlyInit() catch unreachable;
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
    const v: *u64 = @ptrFromInt(addr.toAddr());
    v.* = 123;
    std.log.info("quick mapped value @ {*} {d}", .{ v, v.* });

    std.log.info("cpu has feature sse2 {any}", .{cpu.hasFeature(.sse2)});
    try debug.init(Memory.permanent_allocator);

    descriptors.init();
    try Memory.lateInit();
    try debug.init(Memory.permanent_allocator);

    std.log.info("page allocator test", .{});
    const page_alloc = Memory.page_allocator;
    std.log.debug("page allocator: {any}", .{page_alloc});
    const allocated2 = try page_alloc.allocate(1000, .{});
    std.log.info("allocated 1000 pages at 0x{x}", .{@intFromPtr(allocated2)});
    try page_alloc.free(allocated2, 1000, .{});

    var list = std.ArrayList([]u32){};
    for (0..1000) |_| {
        const a = try kernel_alloc.alloc(u32, 16 * 16);
        try list.append(kernel_alloc, a);
    }

    for (list.items) |a| {
        kernel_alloc.free(a);
    }
    list.deinit(kernel_alloc);

    try Memory.printStats();

    try acpi.init();
    try smp.init();

    // assuming BSP is always cpu#0
    try cpu.initCore(0);
    std.log.info("Present cpus: #{d}, mask: {any}", .{ cpu.present_cpus_count, cpu.present_cpus_mask });
    std.log.info("Online cpus: #{d}, mask: {any}", .{ cpu.online_cpus_count, cpu.online_cpus_mask });

    const count50ms = PIT.millis(50);
    std.log.info("counting down from {d}", .{count50ms});
    var i: u64 = @divExact(5000, 50);
    while (i > 0) : (i -= 1) {
        PIT.wait(count50ms);
    }
    std.log.info("done counting down from {d}", .{32 * @as(u64, @intCast(count50ms))});

    @panic("test");
}
