const std = @import("std");
const arch = @import("arch");
const options = @import("options");
const mem = @import("memory.zig");
const smp = @import("smp.zig");


pub const CpuData = arch.cpu.CpuData;
pub var cpu_info: *arch.cpu.CpuInfo = undefined;
pub const possible_cpus_count = options.max_cpu;
pub var possible_cpus_mask: std.bit_set.ArrayBitSet(u64, possible_cpus_count) = .initEmpty();
pub var present_cpus_count: u16 = 1;
pub var present_cpus_mask: std.bit_set.ArrayBitSet(u64, possible_cpus_count) = .initEmpty();
pub var online_cpus_count: u16 = 1;
pub var online_cpus_mask: std.bit_set.ArrayBitSet(u64, possible_cpus_count) = .initEmpty();

pub var cpu_data: [possible_cpus_count]CpuData align(arch.constants.default_page_size) = undefined;

pub fn earlyInit() !void {
    possible_cpus_mask.setRangeValue(.{ .start = 0, .end = possible_cpus_count }, true);
    cpu_info = try arch.cpu.init();
    try doCpuChecks();
}

fn doCpuChecks() !void {
    if (!hasFeature(.apic)) return error.NoApic;
}

pub fn initCore(cpu_id: arch.cpu.CpuId) !void {
    if (!possible_cpus_mask.isSet(cpu_id)) return error.ImpossibleCpu;
    if (!present_cpus_mask.isSet(cpu_id)) return error.CpuNotPresent;

    setCpuOnline(cpu_id);
    arch.assembly.wrmsr(.GS_BASE, @intFromPtr(&cpu_data[cpu_id]));
    try enableLocalApic();
    initLocalInterrupts();
}

pub fn hasFeature(feature: arch.cpu.Feature) bool {
    return arch.cpu.hasFeature(feature);
}

pub fn setCpuPresent(cpu_id: arch.cpu.CpuId, id_data: arch.cpu.IdentificationData) void {
    present_cpus_mask.set(cpu_id);
    present_cpus_count = @intCast(present_cpus_mask.count());

    cpu_data[cpu_id].id = cpu_id;
    cpu_data[cpu_id].cpu_data = .init(cpu_id, id_data);
}

pub fn setCpuOnline(cpu_id: arch.cpu.CpuId) void {
    online_cpus_mask.set(cpu_id);
    online_cpus_count = @intCast(online_cpus_mask.count());
}

pub fn enableLocalApic() !void {
    if (hasFeature(.x2apic)) {
        try arch.x2apic.init();
    } else {
        try arch.xapic.init(smp.lapic_addr, &mem.kernel_vmem.impl);
    }
}

pub fn initLocalInterrupts() void {
    if (hasFeature(.x2apic)) {
        // TODO: handle local ints for x2apic
    } else {
        arch.xapic.initLocalInterrupts(&smp.local_apic_nmi);
    }
}
