const GDT = @import("descriptors/gdt.zig");

var gdt: GDT = undefined;

pub fn init() void {
    gdt = .init();
}
