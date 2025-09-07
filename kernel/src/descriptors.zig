const std = @import("std");
const GDT = @import("descriptors/gdt.zig");
const IDT = @import("descriptors/idt.zig");
const GateDescriptor = @import("descriptors/types.zig").Segment.GateDescriptor;
const interrupt = @import("interrupt.zig");
const interrupt_types = @import("interrupt/types.zig");
const arch = @import("arch");
const constants = @import("constants");

const log = std.log.scoped(.descriptors);

var stacks: [constants.max_cpu * arch.constants.default_page_size]u8 align(arch.constants.default_page_size) = [_]u8{0} ** (constants.max_cpu * arch.constants.default_page_size);

pub var gdt: GDT = undefined;
pub var idt: IDT = undefined;

const DemoInterruptHandler = struct {
    pub fn InterruptHandler(self: *@This()) interrupt.InterruptHandler {
        return .{.ctx = self, .handler = handleInterrupt};
    }

    fn handleInterrupt(ctx: *anyopaque, context: *const interrupt_types.Context) bool {
        log.info("Demo interrupt handle called !!!!", .{});
        log.info("with ctx {any} and context {any}", .{ctx, context});
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
    idt = .create();
    interrupt.init(&idt);

    // TODO: as part of arch specific code maybe 
    // have an interrupt/exception vectors enum
    var interrupt_handler = demo_handler.InterruptHandler();
    interrupt.registerHandler(0xE, &interrupt_handler);
}
