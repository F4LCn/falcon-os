const std = @import("std");
const GDT = @import("descriptors/gdt.zig");
const IDT = @import("descriptors/idt.zig");
const GateDescriptor = @import("descriptors/types.zig").Segment.GateDescriptor;
const interrupts = @import("interrupts.zig");
const interrupt_context = @import("interrupts/context.zig");
const options = @import("options");
const constants = @import("constants.zig");

const log = std.log.scoped(.descriptors);

var stacks: [options.max_cpu * constants.default_page_size]u8 align(constants.default_page_size) = [_]u8{0} ** (options.max_cpu * constants.default_page_size);

pub var gdt: GDT = undefined;

const DemoInterruptHandler = struct {
    pub fn InterruptHandler(self: *@This()) interrupts.InterruptHandler {
        return .{ .ctx = self, .handler = handleInterrupt };
    }

    fn handleInterrupt(ctx: *anyopaque, context: *const interrupt_context.Context) bool {
        log.info("Demo interrupt handle called !!!!", .{});
        log.info("with ctx {any} and context {any}", .{ ctx, context });
        return false;
    }
};

var demo_handler = DemoInterruptHandler{};

pub fn init() void {
    gdt = .create();
    gdt.fillGDTR();
    gdt.fillTss(&stacks);
    gdt.loadGDTR();
    gdt.loadTR(.{});
    gdt.flushGDT();
    log.info("segment descriptors initialized", .{});

    // TODO: as part of arch specific code maybe
    // have an interrupt/exception vectors enum
    var interrupt_handler = demo_handler.InterruptHandler();
    interrupts.registerHandler(0xE, &interrupt_handler);
}
