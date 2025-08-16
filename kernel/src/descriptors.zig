const GDT = @import("descriptors/gdt.zig");
const IDT = @import("descriptors/idt.zig");
const GateDescriptor = @import("descriptors/types.zig").Segment.GateDescriptor;

var gdt: GDT = undefined;
var idt: IDT = undefined;

fn dummyIsr() callconv(.naked) void {
// do stack magic
//iret
}

pub fn init() void {
    gdt = .init();
    idt = .init();

    idt.registerGate(0, .create(.{.typ = .interrupt_gate, .isr = dummyIsr }));
}
