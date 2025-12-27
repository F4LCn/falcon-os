const std = @import("std");

pub const DescriptionHeader = extern struct {
    sig: [4]u8 align(1),
    len: u32 align(1),
    rev: u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    oem_table_id: [8]u8 align(1),
    oem_rev: u32 align(1),
    creator_id: u32 align(1),
    creator_rev: u32 align(1),
};

pub const TableSignatures = enum(u32) {
    rsdt = std.mem.bytesToValue(u32, "RSDT"),
    xsdt = std.mem.bytesToValue(u32, "XSDT"),
    facp = std.mem.bytesToValue(u32, "FACP"),
    apic = std.mem.bytesToValue(u32, "APIC"),
    hpet = std.mem.bytesToValue(u32, "HPET"),
    waet = std.mem.bytesToValue(u32, "WAET"),
    bgrt = std.mem.bytesToValue(u32, "BGRT"),

    pub fn fromSignature(signature: []const u8) TableSignatures {
        return @enumFromInt(std.mem.bytesToValue(u32, signature));
    }
};

pub const AcpiRsdp = extern struct {
    sig: [8]u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    rev: u8 align(1),
    rsdt_addr: u32 align(1),
    length: u32 align(1),
    xsdt_addr: u64 align(1),
    xchecksum: u8 align(1),
    reserved: [3]u8 align(1),
};

pub const AcpiMadt = extern struct {
    pub const InterruptControllerHeader = extern struct {
        pub const Type = enum(u8) {
            processorLocalApic = 0,
            ioApic = 1,
            interruptSourceOverride = 2,
            nonMaskableInterrupt = 3,
            localApicNMI = 4,
            localApicAddressOverride = 5,
            ioSapic = 6,
            localSapic = 7,
            platformInterruptSource = 8,
            processorLocalx2Apic = 9,
            localx2ApicNMI = 0xA,
            gicCpuInterface = 0xB,
            gicDistributor = 0xC,
            gicMsiFrame = 0xD,
            gicRedistributor = 0xE,
            gicInterruptTranslationService = 0xF,
            multiprocessorWakeup = 0x10,
            coreProgrammableInterruptController = 0x11,
            legacyIoProgrammbleInterruptController = 0x12,
            hyperTransportProgrammableInterruptController = 0x13,
            extendIoProgrammableInterruptController = 0x14,
            msiProgrammableInterruptController = 0x15,
            bridgeIoProgrammableInterruptController = 0x16,
            lowPinCountProgrammableInterruptController = 0x17,
            riscVHartLocalInterruptController = 0x18,
            riscVIncomingMsiController = 0x19,
            riscVAdvancedPlatformLevelInterruptController = 0x1A,
            riscVPlatformLevelInterruptController = 0x1B,
            _,
        };
        typ: Type align(1),
        length: u8 align(1),
    };
    pub const MpsIntiFlags = packed struct(u16) {
        polarity: enum(u2) {
            bus_conforming = 0b00,
            active_high = 0b01,
            reserved = 0b10,
            active_low = 0b11,
        },
        trigger_mode: enum(u2) {
            bus_conforming = 0b00,
            edge_triggered = 0b01,
            reserved = 0b10,
            level_triggered = 0b11,
        },
        reserved: u12,
    };
    pub const ApicFlags = packed struct(u32) {
        enabled: bool,
        online_capable: bool,
        reserved: u30,
    };

    pub const ProcessorLocalApic = extern struct {
        header: InterruptControllerHeader,
        processor_uid: u8,
        apic_id: u8,
        flags: ApicFlags align(1),
    };
    pub const IoApic = extern struct {
        header: InterruptControllerHeader,
        ioapic_id: u8,
        reserved: u8,
        ioapic_addr: u32 align(1),
        global_system_interrupt_base: u32 align(1),
    };
    pub const InterruptSourceOverride = extern struct {
        header: InterruptControllerHeader,
        bus: u8,
        source: u8,
        global_system_interrupt: u32 align(1),
        flags: MpsIntiFlags align(1),
    };
    pub const NonMaskableInterruptSource = extern struct {
        header: InterruptControllerHeader,
        flags: MpsIntiFlags align(1),
        global_system_interrupt: u32 align(1),
    };
    pub const LocalApicNMI = extern struct {
        header: InterruptControllerHeader,
        processor_uid: u8,
        flags: MpsIntiFlags align(1),
        local_apic_lint_num: u8,
    };
    pub const LocalApicAddressOverride = extern struct {
        header: InterruptControllerHeader,
        reserved: u16 align(1),
        local_apic_addr: u64 align(1),
    };
    pub const IoSapic = extern struct {
        header: InterruptControllerHeader,
        ioapic_id: u8,
        reserved: u8,
        global_system_interrupt_base: u32 align(1),
        ioapic_addr: u64 align(1),
    };
    pub const LocalSapic = extern struct {
        header: InterruptControllerHeader,
        processor_id: u8,
        local_sapic_id: u8,
        local_sapic_eid: u8,
        reserved: u24 align(1),
        flags: ApicFlags align(1),
        processor_uid: u32 align(1),
        // processor_uid_string beyond this (null-terminated)
    };
    pub const PlatformInterruptSource = extern struct {
        header: InterruptControllerHeader,
        flags: MpsIntiFlags align(1),
        interrupt_type: enum(u8) { pmi = 1, init = 2, corrected_platform_error_interrupt = 3, _ },
        processor_id: u8,
        processor_eid: u8,
        iosapic_vector: u8,
        global_system_interrupt: u32 align(1),
        platform_interrupt_source_flags: packed struct(u32) { cpei_processor_override: bool, reserved: u31 } align(1),
    };
    pub const ProcessorLocalx2Apic = extern struct {
        header: InterruptControllerHeader,
        reserved: u16 align(1),
        x2apic_id: u32 align(1),
        flags: ApicFlags align(1),
        processor_uid: u32 align(1),
    };
    pub const Localx2ApicNMI = extern struct {
        header: InterruptControllerHeader,
        flags: MpsIntiFlags align(1),
        processor_uid: u32 align(1),
        local_x2apic_lint_num: u8,
        reserved: u24 align(1),
    };

    header: DescriptionHeader,
    lapic_addr: u32 align(1),
    flags: packed struct(u32) { pcat_compat: bool, reserved: u31 } align(1),
    // Interrupt controller structures beyond here up to header.len
};
