const std = @import("std");
const cpu = @import("../cpu.zig");
const assembly = @import("../assembly.zig");
const Apic = @import("apic.zig");
const apic_types = @import("types.zig");
const options = @import("options");
const smp = @import("../smp.zig");

const log = std.log.scoped(.x2apic);

const CpuIdInt = u32;
const CpuIdMask = std.math.maxInt(CpuIdInt);

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

pub fn apicId() cpu.CpuId {
    const id = assembly.rdmsr(.X2APIC_APICID);
    return @intCast(id);
}

const int_mask: u32 = 0x10000;
pub fn initLocalInterrupts(local_apic_nmi: []?smp.LocalApic.ApicNMI) void {
    assembly.wrmsr(.X2APIC_CMCI, int_mask);
    assembly.wrmsr(.X2APIC_LVT_ERROR, int_mask);
    assembly.wrmsr(.X2APIC_LVT_PMC, int_mask);
    assembly.wrmsr(.X2APIC_LVT_THERMAL, int_mask);
    const cpu_id = cpu.perCpu(.id);
    log.debug("cpu_id {d}", .{cpu_id});
    for (local_apic_nmi) |maybe_nmi| {
        if (maybe_nmi) |nmi| {
            if (nmi.cpu_id != cpu_id and nmi.cpu_id != 0xff) continue;
            const msr: cpu.MSR = switch (nmi.lint_num) {
                0 => .X2APIC_LVT_LINT0,
                1 => .X2APIC_LVT_LINT1,
                else => unreachable,
            };
            const trigger: u64 = blk: {
                if (nmi.lint_num == 1) break :blk 0;
                break :blk switch (nmi.trigger_mode) {
                    .bus_conforming, .edge_triggered => 0,
                    .level_triggered => 1 << 15,
                };
            };
            const polarity: u64 = switch (nmi.polarity) {
                .bus_conforming, .active_high => 0,
                .active_low => 1 << 13,
            };
            const delivery_mode: u64 = 4 << 8;
            const val: u64 = trigger | polarity | delivery_mode;
            assembly.wrmsr(msr, val);
        }
    }
}

fn setEnabled(enabled: bool) void {
    const spurious_vector: u64 = 0xff;
    const local_apic_enable: u64 = @as(u64, @intCast(@intFromBool(enabled))) << 8;
    const svr_config = local_apic_enable | spurious_vector;
    assembly.wrmsr(.X2APIC_SIVR, svr_config);
}

fn sendIPI(msg: apic_types.IPIMessage, dest: apic_types.IPIDestination, opts: apic_types.SendIPIOptions) !void {
    if (options.safety) {
        // NOTE: in x2apic mode, there is no wait for send
        std.debug.assert(opts.wait_for_send == false);
    }
    const destination_apic_id: u64 = switch (dest) {
        .apic => |a| a.id,
        else => 0,
    };
    const destination: u64 = (destination_apic_id & CpuIdMask) << 32;
    const destination_shorthand = @intFromEnum(dest);
    const trigger_mode: u32 = 0 << 15;
    const level: u32 = 1 << 14;
    const destination_mode: u32 = 0 << 11;
    const delivery_mode = @intFromEnum(msg);
    const vector = switch (msg) {
        .fixed => |e| e.vector,
        .lowest_priority => |e| e.vector,
        .smi,
        .nmi,
        .init,
        => 0,
        .startup => |s| (s.trampoline >> 12) & 0xff,
    };
    const ipi: u64 = destination | destination_shorthand | trigger_mode | level | destination_mode | delivery_mode | vector;
    assembly.wrmsr(.X2APIC_ICR, ipi);
}

pub fn apic() Apic {
    return .{
        .apic_id = apicId,
        .init_local_interrupts = initLocalInterrupts,
        .set_enabled = setEnabled,
        .send_ipi = sendIPI,
    };
}
