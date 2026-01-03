const apic_types = @import("types.zig");
const cpu = @import("../cpu.zig");
const smp = @import("../smp.zig");

const Self = @This();

apic_id: *const fn () cpu.CpuId,
init_local_interrupts: *const fn ([]?smp.LocalApic.ApicNMI) void,
set_enabled: *const fn (enabled: bool) void,
send_ipi: *const fn (apic_types.IPIMessage, apic_types.IPIDestination, apic_types.SendIPIOptions) anyerror!void,

pub fn apicId(self: Self) cpu.CpuId {
    return self.apic_id();
}

pub fn initLocalInterrupts(self: Self, nmis: []?smp.LocalApic.ApicNMI) void {
    self.init_local_interrupts(nmis);
}

pub fn setEnabled(self: Self, enabled: bool) void {
    self.set_enabled(enabled);
}

pub fn sendIPI(self: Self, msg: apic_types.IPIMessage, dest: apic_types.IPIDestination, opts: apic_types.SendIPIOptions) !void {
    try self.send_ipi(msg, dest, opts);
}
