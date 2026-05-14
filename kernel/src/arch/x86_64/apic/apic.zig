const apic_types = @import("types.zig");
const cpu = @import("../cpu.zig");
const smp = @import("../smp.zig");

const Self = @This();

apic_id: *const fn () cpu.CpuId,
init_interrupts: *const fn ([]?smp.LocalApic.ApicNMI) void,
set_enabled: *const fn (enabled: bool) void,
send_ipi: *const fn (apic_types.IPIMessage, apic_types.IPIDestination, apic_types.SendIPIOptions) anyerror!void,
send_eoi: *const fn() void,
configure_interrupt: *const fn (apic_types.LocalInterrupt, apic_types.InterruptConfiguration) anyerror!void,
mask_interrupt: *const fn (apic_types.LocalInterrupt) anyerror!void,
unmask_interrupt: *const fn (apic_types.LocalInterrupt) anyerror!void,

pub fn apicId(self: Self) cpu.CpuId {
    return self.apic_id();
}

pub fn init(self: Self, nmis: []?smp.LocalApic.ApicNMI) void {
    self.init_interrupts(nmis);
}

pub fn setEnabled(self: Self, enabled: bool) void {
    self.set_enabled(enabled);
}

pub fn sendIPI(self: Self, msg: apic_types.IPIMessage, dest: apic_types.IPIDestination, opts: apic_types.SendIPIOptions) !void {
    try self.send_ipi(msg, dest, opts);
}

pub fn eoi(self: Self) void {
    self.send_eoi();
}

pub fn configure(self: Self, interrupt: apic_types.LocalInterrupt, config: apic_types.InterruptConfiguration) !void {
    try self.configure_interrupt(interrupt, config);
}

pub fn mask(self: Self, interrupt: apic_types.LocalInterrupt) !void {
    try self.mask_interrupt(interrupt);
}

pub fn unmask(self: Self, interrupt: apic_types.LocalInterrupt) !void {
    try self.unmask_interrupt(interrupt);
}
