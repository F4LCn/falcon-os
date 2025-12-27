pub const ApicFoundEvent = struct {
    id: u8,
    apic_id: u8,
    enabled: bool,
    online_capable: bool,
};
pub const IOApicFoundEvent = struct {
    ioapic_addr: u32,
    gsi_base: u32,
    ioapic_id: u8,
};
pub const InterruptFlags = struct {
    pub const Polarity = enum { bus_conforming, active_high, active_low };
    pub const TriggerMode = enum { bus_conforming, edge_triggered, level_triggered };
    polarity: Polarity,
    trigger_mode: TriggerMode,
};
pub const InterruptSourceOverrideFoundEvent = struct {
    gsi: u32,
    bus: u8,
    source: u8,
    flags: InterruptFlags,
};
pub const LocalApicNMIFoundEvent = struct {
    processor_uid: u8,
    lint_num: u8,
    flags: InterruptFlags,
};

pub const MadtParsingEvent = union(enum) {
    local_apic_addr: u32,
    pic_compatibility: void,
    apic: ApicFoundEvent,
    ioapic: IOApicFoundEvent,
    interrupt_source_override: InterruptSourceOverrideFoundEvent,
    local_apic_nmi: LocalApicNMIFoundEvent,
};
