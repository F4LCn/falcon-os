const std = @import("std");
const memory = @import("../memory.zig");
const constants = @import("../constants.zig");
const assembly = @import("../assembly.zig");

const log = std.log.scoped(.xapic);

const Registers = enum(u16) {
    id = 0x020,
    version = 0x030,
    task_priority = 0x080,
    processor_priority = 0x0A0,
    eoi = 0x0B0,
    logical_destination = 0x0D0,
    destination_format = 0x0E0,
    spurious_interrupt_vector = 0x0F0,
    isr0 = 0x100,
    isr1 = 0x110,
    isr2 = 0x120,
    isr3 = 0x130,
    isr4 = 0x140,
    isr5 = 0x150,
    isr6 = 0x160,
    isr7 = 0x170,
    tmr0 = 0x180,
    tmr1 = 0x190,
    tmr2 = 0x1A0,
    tmr3 = 0x1B0,
    tmr4 = 0x1C0,
    tmr5 = 0x1D0,
    tmr6 = 0x1E0,
    tmr7 = 0x1F0,
    irr0 = 0x200,
    irr1 = 0x210,
    irr2 = 0x220,
    irr3 = 0x230,
    irr4 = 0x240,
    irr5 = 0x250,
    irr6 = 0x260,
    irr7 = 0x270,
    error_status = 0x280,
    lvt_corrected_machine_check_interrupt = 0x2F0,
    interrupt_command_low = 0x300,
    interrupt_command_high = 0x310,
    lvt_timer = 0x320,
    lvt_thermal_sensor = 0x330,
    lvt_performance_monitoring_counters = 0x340,
    lvt_lint0 = 0x350,
    lvt_lint1 = 0x360,
    lvt_error = 0x370,
    initial_count = 0x380,
    current_count = 0x390,
    divide_configuration = 0x3E0,
};

var phys_lapic_base: memory.PAddr = undefined;
var lapic_base: memory.VAddr = undefined;
pub fn init(lapic_base_addr: memory.PAddr, page_map: *memory.PageMapManager) !void {
    log.debug("initializing xAPIC (base: 0x{x})", .{lapic_base_addr});
    phys_lapic_base = lapic_base_addr;
    lapic_base = page_map.physToVirt(phys_lapic_base);
    log.debug("mapped xAPIC base to 0x{x}", .{lapic_base.toAddr()});
    try page_map.mmap(
        .{
            .start = lapic_base_addr,
            .length = constants.default_page_size,
            .typ = .acpi,
        },
        .{
            .start = lapic_base,
            .length = constants.default_page_size,
        },
        memory.DefaultFlags.extend(.{
            .read_write = .read_write,
            .cache_control = .uncacheable,
        }),
        .{ .remap = true },
    );

    const id = readRegister(.id);
    log.debug("xAPIC id {x}", .{id});
    const version = readRegister(.version);
    log.debug("xAPIC version {x}", .{version});

    var apic_base = assembly.rdmsr(.APIC_BASE);
    log.debug("xAPIC status {x}", .{apic_base});
    apic_base |= 1 << 11;
    assembly.wrmsr(.APIC_BASE, apic_base);

    log.info("xAPIC enabled", .{});
}

fn readRegister(offset: Registers) u32 {
    const register_addr = lapic_base.toAddr() + @intFromEnum(offset);
    const register_ptr: *u32 = @ptrFromInt(register_addr);
    return register_ptr.*;
}
