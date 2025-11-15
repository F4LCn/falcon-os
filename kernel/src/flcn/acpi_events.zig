pub const ApicFoundEvent = struct {
    id: u8,
    apic_id: u8,
    enabled: bool,
    online_capable: bool,
};

pub const MadtParsingEvent = union(enum) {
    local_apic_addr: u32,
    pic_compatibility: void,
    apic: ApicFoundEvent,
};
