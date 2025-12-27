const acpi_events = @import("flcn").acpi_events;

const Self = @This();
init_local_interrupts: *const fn ([]?acpi_events.LocalApicNMIFoundEvent) void,

pub fn initLocalInterrupts(self: Self, local_apic_nmi: []?acpi_events.LocalApicNMIFoundEvent) void {
    self.init_local_interrupts(local_apic_nmi);
}
