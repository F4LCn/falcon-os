const std = @import("std");
const cpu = @import("../cpu.zig");
const assembly = @import("../assembly.zig");
const acpi_events = @import("flcn").acpi_events;
const Apic = @import("apic.zig");

const log = std.log.scoped(.x2apic);

pub fn init() !void {
    log.debug("initializing x2APIC (base: 0x{x})", .{cpu.MSR.APIC_BASE});

    const id = assembly.rdmsr(.X2APIC_APICID);
    log.debug("x2APIC id {x}", .{id});
    const version = assembly.rdmsr(.X2APIC_VERSION);
    log.debug("x2APIC version {x}", .{version});

    var apic_base = assembly.rdmsr(.APIC_BASE);
    log.debug("x2APIC status {x}", .{apic_base});
    apic_base |= 1 << 11;
    assembly.wrmsr(.APIC_BASE, apic_base);
    log.info("x2APIC enabled", .{});
}

const int_mask: u32 = 0x10000;
pub fn initLocalInterrupts(local_apic_nmi: []?acpi_events.LocalApicNMIFoundEvent) void {
    assembly.wrmsr(.X2APIC_CMCI, int_mask);
    assembly.wrmsr(.X2APIC_LVT_ERROR, int_mask);
    assembly.wrmsr(.X2APIC_LVT_PMC, int_mask);
    assembly.wrmsr(.X2APIC_LVT_THERMAL, int_mask);
    const cpu_id = cpu.perCpu(.id);
    log.debug("cpu_id {d}", .{cpu_id});
    for (local_apic_nmi) |maybe_nmi| {
        if (maybe_nmi) |nmi| {
            if (nmi.processor_uid != cpu_id and nmi.processor_uid != 0xff) continue;
            const msr: cpu.MSR = switch (nmi.lint_num) {
                0 => .X2APIC_LVT_LINT0,
                1 => .X2APIC_LVT_LINT1,
                else => unreachable,
            };
            const trigger: u64 = blk: {
                if (nmi.lint_num == 1) break :blk 0;
                break :blk switch (nmi.flags.trigger_mode) {
                    .bus_conforming, .edge_triggered => 0,
                    .level_triggered => 1 << 15,
                };
            };
            const polarity: u64 = switch (nmi.flags.polarity) {
                .bus_conforming, .active_high => 0,
                .active_low => 1 << 13,
            };
            const delivery_mode: u64 = 4 << 8;
            const val: u64 = trigger | polarity | delivery_mode;
            assembly.wrmsr(msr, val);
        }
    }
}

pub fn apic() Apic {
    return .{
        .init_local_interrupts = initLocalInterrupts,
    };
}
