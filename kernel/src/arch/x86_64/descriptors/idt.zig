const std = @import("std");
const options = @import("options");
const constants = @import("../constants.zig");
const Segment = @import("types.zig").Segment;

const log = std.log.scoped(.idt);
const Self = @This();
const IDTR = packed struct {
    limit: u16,
    base: *[constants.max_interrupt_vectors]Segment.GateDescriptor,
};
idt_entries: [constants.max_interrupt_vectors]Segment.GateDescriptor align(constants.default_page_size) = [_]Segment.GateDescriptor{std.mem.zeroes(Segment.GateDescriptor)} ** constants.max_interrupt_vectors,
idtr: IDTR = undefined,

pub fn create() Self {
    return .{};
}

pub fn loadIDTR(self: *Self) void {
    self.idtr = .{
        .limit = (@sizeOf(Segment.GateDescriptor) * constants.max_interrupt_vectors) - 1,
        .base = &self.idt_entries,
    };
    log.info("loading IDTR {*}", .{self.idtr.base});
    asm volatile (
        \\lidt (%[idtr])
        :
        : [idtr] "r" (@intFromPtr(&self.idtr)),
    );
}

pub fn registerGate(self: *Self, vector: u8, gate_descriptor: Segment.GateDescriptor) void {
    self.idt_entries[vector] = gate_descriptor;
}
