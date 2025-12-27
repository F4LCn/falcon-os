const std = @import("std");
const flcn = @import("flcn");
const acpi = flcn.acpi;
const acpi_events = @import("flcn").acpi_events;
const cpu = flcn.cpu;
const trampoline = @import("trampoline.zig");
const options = @import("options");

const log = std.log.scoped(.smp);

const MadtIterationContext = struct {
    pub fn acpiIterationContext(self: *const MadtIterationContext) acpi.AcpiTableIterationContext {
        return .{
            .ptr = self,
            .cb = onCallback,
        };
    }

    fn onCallback(_: *const anyopaque, args: anytype) void {
        const msg: acpi_events.MadtParsingEvent = args;
        switch (msg) {
            .local_apic_addr => |laa| {
                setLocalApicAddr(laa);
            },
            .pic_compatibility => {
                setPicCompatible();
            },
            .apic => |apic| {
                setCpuPresent(apic.id, apic.apic_id);
            },
            .ioapic => |io| {
                setIOApicAddr(io.ioapic_addr);
                // setIOApicGSIBase(io.ioapic_id, io.gsi_base);
            },
            .interrupt_source_override => {},
            .local_apic_nmi => |nmi| {
                log.debug("nmi: {any}", .{nmi});
                if (nmi.processor_uid >= options.max_cpu) return;
                const idx = nmi.processor_uid +% 1;
                local_apic_nmi[idx] = nmi;
            },
        }
    }
};

// local apic
pub var lapic_addr: u32 = undefined;
var pic_compatibility: bool = false;

// io apic
pub var ioapic_addr: u32 = undefined;

// local apic nmi
pub var local_apic_nmi: [options.max_cpu + 1]?acpi_events.LocalApicNMIFoundEvent = .{null} ** (options.max_cpu + 1);

pub fn init() !void {
    const madtIterationContext = MadtIterationContext{};
    try acpi.iterateTable(.apic, madtIterationContext.acpiIterationContext());

    log.debug("trampoline data {s} {d} {*}", .{ std.fmt.bytesToHex(trampoline.trampoline_data, .lower), trampoline.trampoline_data.len, trampoline.trampoline_data });
}

// EL PLAN:
// 1/ identify cpu count (done)
// 2/ create a trampoline page (done)
// 2.5/ write the startup code (small bootloader: takes the core from real mode to long mode AFAP)
// 3/ copy the startup code to the trampoline
// 4/ have a special path in our kernel entrypoint for APs

fn setLocalApicAddr(addr: u32) void {
    lapic_addr = addr;
}

fn setIOApicAddr(addr: u32) void {
    ioapic_addr = addr;
}

fn setPicCompatible() void {
    pic_compatibility = true;
}

fn setCpuPresent(cpu_id: u8, apic_id: u8) void {
    cpu.setCpuPresent(cpu_id, .{ .apic_id = apic_id, .lapic_addr = lapic_addr });
}
