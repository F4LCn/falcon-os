const std = @import("std");
const arch = @import("arch");
const options = @import("options");

pub const cpu_info: *arch.cpu.CpuInfo = undefined;
pub const max_cpu_count = options.max_cpu;
pub const possible_cpus_mask: std.bit_set.ArrayBitSet(max_cpu_count) = .initEmpty();
pub var present_cpus_count: u16 = 1;
pub var present_cpus_mask: std.bit_set.ArrayBitSet(max_cpu_count) = .initEmpty();
pub var online_cpus_count: u16 = 1;
pub var online_cpus_mask: std.bit_set.ArrayBitSet(max_cpu_count) = .initEmpty();

comptime {
    possible_cpus_mask.setRangeValue(.{ .start = 0, .end = max_cpu_count }, true);
}

pub fn init() !void {
    cpu_info = try arch.cpu.init();
}

pub fn hasFeature(feature: arch.cpu.Feature) bool {
    return arch.cpu.hasFeature(feature);
}

pub fn setCpuPresent(cpu_id: arch.cpu.CpuId) void {
    present_cpus_mask.set(cpu_id);
    present_cpus_count = present_cpus_mask.count();
}

pub fn setCpuOnline(cpu_id: arch.cpu.CpuId) void {
    online_cpus_mask.set(cpu_id);
    online_cpus_count = online_cpus_mask.count();
}
