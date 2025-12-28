const std = @import("std");
const memory = @import("../memory.zig");
const constants = @import("../constants.zig");
const assembly = @import("../assembly.zig");
const flcn = @import("flcn");
const acpi_events = flcn.acpi_events;
const cpu = @import("../cpu.zig");
const Apic = @import("apic.zig");

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

pub fn apicId() cpu.CpuId {
    const id = readRegister(.id);
    return @intCast(id >> 24);
}

const int_mask: u32 = 0x10000;
pub fn initLocalInterrupts(local_apic_nmi: []?acpi_events.LocalApicNMIFoundEvent) void {
    writeRegister(.lvt_corrected_machine_check_interrupt, int_mask);
    writeRegister(.lvt_error, int_mask);
    writeRegister(.lvt_performance_monitoring_counters, int_mask);
    writeRegister(.lvt_thermal_sensor, int_mask);
    const cpu_id = cpu.perCpu(.id);
    log.debug("cpu_id {d}", .{cpu_id});
    for (local_apic_nmi) |maybe_nmi| {
        if (maybe_nmi) |nmi| {
            if (nmi.processor_uid != cpu_id and nmi.processor_uid != 0xff) continue;
            const register: Registers = switch (nmi.lint_num) {
                0 => .lvt_lint0,
                1 => .lvt_lint1,
                else => unreachable,
            };
            const trigger: u32 = blk: {
                if (nmi.lint_num == 1) break :blk 0;
                break :blk switch (nmi.flags.trigger_mode) {
                    .bus_conforming, .edge_triggered => 0,
                    .level_triggered => 1 << 15,
                };
            };
            const polarity: u32 = switch (nmi.flags.polarity) {
                .bus_conforming, .active_high => 0,
                .active_low => 1 << 13,
            };
            const delivery_mode: u32 = 4 << 8;
            const val: u32 = trigger | polarity | delivery_mode;
            writeRegister(register, val);
        }
    }
}

fn readRegister(register: Registers) u32 {
    const register_addr = lapic_base.toAddr() + @intFromEnum(register);
    const register_ptr: *u32 = @ptrFromInt(register_addr);
    return register_ptr.*;
}

fn writeRegister(register: Registers, val: u32) void {
    const register_addr = lapic_base.toAddr() + @intFromEnum(register);
    const register_ptr: *u32 = @ptrFromInt(register_addr);
    register_ptr.* = val;
}

pub fn apic() Apic {
    return .{
        .apic_id = apicId,
        .init_local_interrupts = initLocalInterrupts,
    };
}
