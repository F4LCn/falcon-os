const std = @import("std");
const acpi = @import("acpi.zig");
const acpi_events = @import("flcn").acpi_events;
const cpu = @import("cpu.zig");
const arch = @import("arch");
const trampoline = arch.trampoline;
const mem = @import("memory.zig");

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
        }
    }
};

var lapic_addr: u32 = undefined;
var pic_compatibility: bool = false;

pub fn init() !void {
    const madtIterationContext = MadtIterationContext{};
    try acpi.iterateTable(.apic, madtIterationContext.acpiIterationContext());
    log.info("trampoline data {s} {d} {*}", .{ std.fmt.bytesToHex(trampoline.trampoline_data, .lower), trampoline.trampoline_data.len, trampoline.trampoline_data });

    if (cpu.hasFeature(.x2apic)) {
        try arch.x2apic.init();
    } else {
        try arch.xapic.init(lapic_addr, &mem.kernel_vmem.impl);
    }
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

fn setPicCompatible() void {
    pic_compatibility = true;
}

fn setCpuPresent(cpu_id: u8, apic_id: u8) void {
    cpu.setCpuPresent(cpu_id, .{ .apic_id = apic_id, .lapic_addr = lapic_addr });
}
