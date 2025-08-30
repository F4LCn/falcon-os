const std = @import("std");
const arch = @import("arch");

pub var cpu_info: *arch.cpu.CpuInfo = undefined;

pub fn init() !void {
    cpu_info = try arch.cpu.init();
}

pub fn hasFeature(feature: arch.cpu.Feature) bool {
    return arch.cpu.hasFeature(feature);
}
