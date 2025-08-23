const std = @import("std");
const GDT = @import("descriptors/gdt.zig");
const IDT = @import("descriptors/idt.zig");
const GateDescriptor = @import("descriptors/types.zig").Segment.GateDescriptor;
const interrupt = @import("interrupt.zig");

const log = std.log.scoped(.descriptors);

pub var gdt: GDT = undefined;
pub var idt: IDT = undefined;

pub fn init() void {
    gdt = .create();
    gdt.loadGDTR();
    gdt.flushGDT();
    idt = .create();
    interrupt.init(&idt);
}
