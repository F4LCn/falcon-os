const std = @import("std");
const flcn = @import("flcn");
const acpi = flcn.acpi;
const acpi_events = @import("flcn").acpi_events;
const cpu = flcn.cpu;
const trampoline = @import("trampoline.zig");
const options = @import("options");

const log = std.log.scoped(.smp);

pub const Polarity = enum { bus_conforming, active_high, active_low };
pub const TriggerMode = enum { bus_conforming, edge_triggered, level_triggered };
pub const LocalApic = struct {
    pub const ApicNMI = struct {
        cpu_id: cpu.CpuId,
        lint_num: u8,
        polarity: Polarity,
        trigger_mode: TriggerMode,
    };
    address: u32 = undefined,
    nmis: [options.max_cpu + 1]?ApicNMI = .{null} ** (options.max_cpu + 1),
};
pub const IoApic = struct {
    id: u8,
    address: u32,
    gsi_base: u32,
};
pub const IntSourceOverride = struct {
    bus: u8,
    source: u8,
    gsi: u32,
    polarity: Polarity,
    trigger_mode: TriggerMode,
};

const MadtIterationContext = struct {
    pub fn acpiIterationContext(self: *const MadtIterationContext) acpi.AcpiTableIterationContext {
        return .{
            .ptr = self,
            .cb = onCallback,
        };
    }

    fn onCallback(_: *const anyopaque, args: anytype) !void {
        const msg: acpi_events.MadtParsingEvent = args;
        switch (msg) {
            .local_apic_addr => |laa| {
                local_apic.address = laa;
            },
            .apic => |apic| {
                setCpuPresent(apic.id, apic.apic_id);
            },
            .ioapic => |io| {
                if (io.ioapic_id >= options.max_cpu) return error.TooManyIoApics;
                try ioapics.appendBounded(.{
                    .id = io.ioapic_id,
                    .address = io.ioapic_addr,
                    .gsi_base = io.gsi_base,
                });
            },
            .interrupt_source_override => |iso| {
                try int_source_overrides.appendBounded(.{
                    .bus = iso.bus,
                    .source = iso.source,
                    .gsi = iso.gsi,
                    .polarity = switch (iso.flags.polarity) {
                        .bus_conforming => .bus_conforming,
                        .active_low => .active_low,
                        .active_high => .active_high,
                    },
                    .trigger_mode = switch (iso.flags.trigger_mode) {
                        .bus_conforming => .bus_conforming,
                        .edge_triggered => .edge_triggered,
                        .level_triggered => .level_triggered,
                    },
                });
            },
            .local_apic_nmi => |nmi| {
                if (nmi.processor_uid >= options.max_cpu) return;
                const idx = nmi.processor_uid +% 1;
                local_apic.nmis[idx] = .{
                    .cpu_id = nmi.processor_uid,
                    .lint_num = nmi.lint_num,
                    .polarity = switch (nmi.flags.polarity) {
                        .bus_conforming => .bus_conforming,
                        .active_low => .active_low,
                        .active_high => .active_high,
                    },
                    .trigger_mode = switch (nmi.flags.trigger_mode) {
                        .bus_conforming => .bus_conforming,
                        .edge_triggered => .edge_triggered,
                        .level_triggered => .level_triggered,
                    },
                };
            },
        }
    }
};

// local apic
pub var local_apic: LocalApic = .{};

// io apic
var ioapics_buffer: [options.max_cpu]IoApic = .{undefined} ** options.max_cpu;
pub var ioapics: std.ArrayList(IoApic) = .initBuffer(&ioapics_buffer);
var iso_buffer: [std.math.maxInt(u8)]IntSourceOverride = .{undefined} ** std.math.maxInt(u8);
pub var int_source_overrides: std.ArrayList(IntSourceOverride) = .initBuffer(&iso_buffer);

pub fn init() !void {
    const madtIterationContext = MadtIterationContext{};
    try acpi.iterateTable(.apic, madtIterationContext.acpiIterationContext());

    log.debug("ioapics: {any}", .{ioapics.items});
    log.debug("int source overrides: {any}", .{int_source_overrides.items});
    log.debug("trampoline data {d} {*}", .{ trampoline.trampoline_data.len, trampoline.trampoline_data });
}

// EL PLAN:
// 1/ identify cpu count (done)
// 2/ create a trampoline page (done)
// 2.5/ write the startup code (small bootloader: takes the core from real mode to long mode AFAP)
// 3/ copy the startup code to the trampoline
// 4/ have a special path in our kernel entrypoint for APs
// 5/ initiate the INIT SIPI SIPI sequence to start up the APs

fn setCpuPresent(cpu_id: u8, apic_id: u8) void {
    cpu.setCpuPresent(cpu_id, .{ .apic_id = apic_id, .lapic_addr = local_apic.address });
}
