const std = @import("std");
const cpu = @import("../cpu.zig");
const assembly = @import("../assembly.zig");

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
