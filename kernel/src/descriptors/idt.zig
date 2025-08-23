const std = @import("std");
const constants = @import("constants");
const Segment = @import("types.zig").Segment;

const Self = @This();
const IDTR = packed struct {
    limit: u16,
    base: *[constants.max_interrupt_vectors]Segment.GateDescriptor,
};
idt_entries: [constants.max_interrupt_vectors]Segment.GateDescriptor align(constants.arch_page_size) = [_]Segment.GateDescriptor{std.mem.zeroes(Segment.GateDescriptor)} ** constants.max_interrupt_vectors,
idtr: IDTR = undefined,

pub fn create() Self {
    return .{};
}

pub fn loadIDTR(self: *Self) void {
    self.idtr = .{
        .limit = (@sizeOf(Segment.GateDescriptor) * constants.max_interrupt_vectors) - 1,
        .base = &self.idt_entries,
    };
    asm volatile (
        \\lidt (%[idtr])
        :
        : [idtr] "r" (@intFromPtr(&self.idtr)),
    );
}

pub fn registerGate(self: *Self, vector: u8, gate_descriptor: Segment.GateDescriptor) void {
    self.idt_entries[vector] = gate_descriptor;
}
