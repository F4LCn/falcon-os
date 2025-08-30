const std = @import("std");
const GDT = @import("descriptors/gdt.zig");
const IDT = @import("descriptors/idt.zig");
const GateDescriptor = @import("descriptors/types.zig").Segment.GateDescriptor;
const interrupt = @import("interrupt.zig");
const arch = @import("arch");
const constants = @import("constants");

const log = std.log.scoped(.descriptors);

var stacks: [constants.max_cpu * arch.constants.default_page_size]u8 align(arch.constants.default_page_size) = [_]u8{0} ** (constants.max_cpu * arch.constants.default_page_size);

pub var gdt: GDT = undefined;
pub var idt: IDT = undefined;

pub fn init() void {
    gdt = .create();
    gdt.fillGDTR();
    gdt.fillTss(&stacks);
    gdt.loadGDTR();
    gdt.loadTR(.{});
    gdt.flushGDT();
    idt = .create();
    interrupt.init(&idt);
}
