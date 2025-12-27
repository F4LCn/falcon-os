const std = @import("std");
const flcn = @import("flcn");
const logger = flcn.logger;
const serial = flcn.serial;
const constants = @import("constants.zig");
const descriptors = @import("descriptors.zig");
const cpu = flcn.cpu;
const Memory = flcn.memory;
const debug = flcn.debug; 
const acpi = flcn.acpi;
const smp = @import("smp.zig");
const pit = flcn.pit;
const panicFn = flcn.panic.panicFn;

pub const panic = std.debug.FullPanic(panicFn);

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .debug, .level = .info },
        .{ .scope = .@"x86_64.memory", .level = .info },
    },
    .page_size_min = constants.default_page_size,
    .page_size_max = constants.default_page_size,
};

pub fn start() callconv(.naked) noreturn {
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
    std.log.info("hello, world", .{});
    std.log.info("Cpu vendor id: {s}", .{cpu.cpu_info.vendor_str[0..12]});

    failableMain() catch |e| {
        std.log.err("Failed with error: {any}", .{e});
    };
}

pub fn failableMain() !void {
    try Memory.earlyInit();
    const kernel_alloc = Memory.allocator();

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

    const count50ms = pit.millis(50);
    std.log.info("counting down from {d}", .{count50ms});
    var i: u64 = @divExact(5000, 50);
    while (i > 0) : (i -= 1) {
        pit.wait(count50ms);
    }
    std.log.info("done counting down from {d}", .{32 * @as(u64, @intCast(count50ms))});

    @panic("test");
}
