const std = @import("std");
const BootInfo = @import("bootinfo.zig").BootInfo;
const logger = @import("log/logger.zig");
const cpu = @import("cpu.zig");
const serial = @import("log/serial.zig");
const heap = @import("heap.zig");
const pmem = @import("memory/pmem.zig");
const vmem = @import("memory/vmem.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};

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
    cpu.init();
    std.log.info("Cpu vendor id: {s}", .{cpu.cpu_info.vendor_str[0..12]});

    failableMain() catch |e| {
        std.log.err("Failed with error: {any}", .{e});
    };
}

pub fn failableMain() !void {
    const alloc = heap.allocator();
    var list = std.ArrayList(u32).init(alloc);
    try list.append(1);
    try list.append(10);
    try list.append(5434);

    for (list.items, 0..) |item, i| {
        std.log.info("item[{d}] = {d}", .{ i, item });
    }

    const permAlloc = heap.permanentAllocator();
    var list2 = std.ArrayList(u32).init(permAlloc);
    try list2.append(1);
    try list2.append(10);
    try list2.append(5434);

    for (list2.items, 0..) |item, i| {
        std.log.info("item[{d}] = {d}", .{ i, item });
    }

    try pmem.init(heap.permanentAllocator());
    const range = pmem.allocatePage(10, .{});
    std.log.info("Allocated range: {any}", .{range});
    pmem.printFreeRanges();

    var kernel_vmem = try vmem.init(heap.permanentAllocator());
    kernel_vmem.printFreeRanges();
    kernel_vmem.printReservedRanges();
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

    v.* = 321;
    std.log.info("value @ {*} {d} {d}", .{ v, v.*, v_id_mapped.* });
}
