const std = @import("std");
const builtin = @import("builtin");
const flcn = @import("flcn");
const logger = flcn.logger;
const serial = flcn.serial;
const constants = @import("constants.zig");
const descriptors = @import("descriptors.zig");
const interrupts = @import("interrupts.zig");
const cpu = flcn.cpu;
const Memory = flcn.memory;
const debug = flcn.debug;
const acpi = flcn.acpi;
const smp = @import("smp.zig");
const pit = flcn.pit;
const panicFn = flcn.panic.panicFn;
const BootInfo = flcn.bootinfo.BootInfo;
const assembly = @import("assembly.zig");

pub const panic = std.debug.FullPanic(panicFn);
const log = std.log.scoped(.entrypoint);
extern var bootinfo: BootInfo;

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = if (builtin.mode == .ReleaseFast) .info else .debug,
    .log_scope_levels = &.{
        .{ .scope = .debug, .level = .info },
        .{ .scope = .@"x86_64.memory", .level = .info },
    },
    .page_size_min = constants.default_page_size,
    .page_size_max = constants.default_page_size,
};

pub fn start() callconv(.naked) noreturn {
    asm volatile (
    // Are we an AP ?
    // set up the AP stack
    // jump to AP specific startup code
    // if we're an AP, get the AP cpu id
    // stack start = -(AP cpu id * core stack size)
    // mov rax, CpuId
    // mul rax, core_stack_size
    // xor rbx, rbx
    // sub rbx, rax
        \\ mov $0, %rbp
        \\ mov %rbp, %rsp
        \\ call kernelMain
    );
    while (true) {}
}

pub fn apstart() callconv(.naked) noreturn {
    _ = cpu.cpu_count.fetchAdd(1, .monotonic);
    assembly.haltEternally();
    while (true) {}
}

export fn kernelMain() callconv(.c) void {
    logger.init(serial.Port.COM1);
    cpu.earlyInit() catch unreachable;
    log.debug("Cpu vendor id: {s}", .{cpu.cpu_info.vendor_str[0..12]});

    failableMain() catch |e| {
        log.err("Failed with error: {any}", .{e});
    };
}

fn failableMain() !void {
    try Memory.earlyInit();
    try Memory.init();
    try debug.init(Memory.permanent_allocator);
    descriptors.init();
    interrupts.init();
    try Memory.lateInit();
    try Memory.printStats();
    try acpi.init();
    try smp.init();
    try cpu.initCore();
    try smp.wakeUpCores();
    log.debug("Present cpus: #{d}, mask: {any}", .{ cpu.present_cpus_count, cpu.present_cpus_mask });
    log.debug("Online cpus: #{d}, mask: {any}", .{ cpu.online_cpus_count, cpu.online_cpus_mask });
    try flcn.irq.init();

    // const count50ms = pit.millis(50);
    // log.info("counting down from {d}", .{count50ms});
    // var i: u64 = @divExact(5000, 50);
    // while (i > 0) : (i -= 1) {
    //     pit.wait(count50ms);
    // }
    // log.info("done counting down from {d}", .{32 * @as(u64, @intCast(count50ms))});

    const irq_handle = try flcn.irq.register(.{
        .source = .{ .vector = 0xfd, .kind = .fixed },
        .config = .{ .masked = false },
        .name = "ipi test",
        .route = .any,
        .handler = .{ .handler_fn = onIPI },
    });
    const apic = cpu.perCpu(.apic);
    try apic.sendIPI(.{ .fixed = .{ .vector = 0xfd } }, .self, .{});
    try flcn.irq.release(irq_handle);

    @panic("test");
}

fn onIPI(context: *const interrupts.interrupt_context.Context, _: ?*anyopaque) void {
    log.info("ipi called {any}", .{context});
}
