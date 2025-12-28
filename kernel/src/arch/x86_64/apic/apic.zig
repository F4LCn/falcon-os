const acpi_events = @import("flcn").acpi_events;
const cpu = @import("../cpu.zig");

const Self = @This();

apic_id: *const fn () cpu.CpuId,
init_local_interrupts: *const fn ([]?acpi_events.LocalApicNMIFoundEvent) void,

pub fn apicId(self: Self) cpu.CpuId {
    return self.apic_id();
}

pub fn initLocalInterrupts(self: Self, local_apic_nmi: []?acpi_events.LocalApicNMIFoundEvent) void {
    self.init_local_interrupts(local_apic_nmi);
}
