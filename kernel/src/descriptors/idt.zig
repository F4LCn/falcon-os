const std = @import("std");
const Segment = @import("types.zig").Segment;
const Constants = @import("../constants.zig");

const Self = @This();
const max_interrupt_vectors = 256;
const IDTR = packed struct {
    limit: u16,
    base: *[max_interrupt_vectors]Segment.GateDescriptor,
};
idt_entries: [max_interrupt_vectors]Segment.GateDescriptor align(Constants.arch_page_size) = [_]Segment.GateDescriptor{std.mem.zeroes(Segment.GateDescriptor)} ** max_interrupt_vectors,
idtr: IDTR = undefined,

pub fn init() Self {
    var _idt: Self = .{};
    _idt.idtr = .{
        .limit = (@sizeOf(Segment.GateDescriptor) * max_interrupt_vectors) - 1,
        .base = &_idt.idt_entries,
    };

    _idt.loadIDTR();
    return _idt;
}

fn loadIDTR(self: *Self) void {
    asm volatile (
        \\lidt (%[idtr])
        :
        : [idtr] "r" (@intFromPtr(&self.idtr)),
    );
}

pub fn registerGate(self: *Self, vector: u8, gate_descriptor: Segment.GateDescriptor) void {
    self.idt_entries[vector] = gate_descriptor;
}
