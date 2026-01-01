const acpi_events = @import("flcn").acpi_events;
const apic_types = @import("types.zig");
const cpu = @import("../cpu.zig");

const Self = @This();

apic_id: *const fn () cpu.CpuId,
init_local_interrupts: *const fn ([]?acpi_events.LocalApicNMIFoundEvent) void,
set_enabled: *const fn (enabled: bool) void,
send_ipi: *const fn (apic_types.IPIMessage, apic_types.IPIDestination, apic_types.SendIPIOptions) anyerror!void,

pub fn apicId(self: Self) cpu.CpuId {
    return self.apic_id();
}

pub fn initLocalInterrupts(self: Self, local_apic_nmi: []?acpi_events.LocalApicNMIFoundEvent) void {
    self.init_local_interrupts(local_apic_nmi);
}

pub fn setEnabled(self: Self, enabled: bool) void {
    self.set_enabled(enabled);
}

pub fn sendIPI(self: Self, msg: apic_types.IPIMessage, dest: apic_types.IPIDestination, opts: apic_types.SendIPIOptions) !void {
    try self.send_ipi(msg, dest, opts);
}
