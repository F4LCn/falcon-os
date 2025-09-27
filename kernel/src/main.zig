const std = @import("std");
const constants = @import("constants");
const BootInfo = @import("bootinfo.zig").BootInfo;
const logger = @import("log/logger.zig");
const cpu = @import("cpu.zig");
const serial = @import("log/serial.zig");
const heap = @import("heap.zig");
const mem = @import("memory.zig");
const descriptors = @import("descriptors.zig");
const debug = @import("debug.zig");
const arch = @import("arch");
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
    const permAlloc = heap.permanentAllocator();
    try debug.init(permAlloc);

    var kernel_heap = try heap.earlyInit();
    const kernel_alloc = kernel_heap.allocator();
    const allocated = try kernel_alloc.alloc(u64, 10);
    defer kernel_alloc.free(allocated);
    allocated[0] = 42;
    for (0.., allocated) |i, a| {
        std.log.info("allocated[{d}] = {d}", .{ i, a });
    }

    std.log.info("Initializing physical memory manager", .{});
    try mem.pmem.init(permAlloc);
    const range = try mem.pmem.allocatePages(10, .{});
    std.log.info("Allocated range: {any}", .{range});
    // pmem.printFreeRanges();

    std.log.info("Initializing virtual memory manager", .{});
    var kernel_vmem = try mem.vmem.init(permAlloc);
    kernel_heap.setVmm(&kernel_vmem);
    // kernel_vmem.printFreeRanges();
    // kernel_vmem.printReservedRanges();

    std.log.info("Quick mapping", .{});
    const addr = kernel_vmem.quickMap(0x14000);
    const v_id_mapped: *u64 = @ptrFromInt(0x14000);
    v_id_mapped.* = 456;
    const v: *u64 = @ptrFromInt(addr);
    v.* = 123;
    std.log.info("quick mapped value @ {*} {d} {d}", .{ v, v.*, v_id_mapped.* });
    kernel_vmem.quickUnmap();

    v_id_mapped.* = 654;
    std.log.info("value @ {d}", .{v_id_mapped.*});

    // v.* = 321;
    // std.log.info("value @ {*} {d} {d}", .{ v, v.*, v_id_mapped.* });
    std.log.info("cpu has feature sse2 {any}", .{cpu.hasFeature(.sse2)});

    descriptors.init();

    try kernel_heap.extend(200 * mem.mb);

    // v.* = 321;
    // std.log.info("value @ {*} {d} {d}", .{ v, v.*, v_id_mapped.* });
    @panic("test");
}
