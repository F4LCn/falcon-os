const std = @import("std");
const assembly = @import("assembly.zig");
const flcn = @import("flcn");
const apic = @import("apic.zig");
const smp = @import("smp.zig");
const cpu_features = @import("cpu/features.zig");
const cpu_msr = @import("cpu/msr.zig");
const cpu_debug_context = @import("cpu/debug_context.zig");
const memory = flcn.memory;
const Apic = @import("apic/apic.zig");

pub const CpuId = u32;

pub const IdentificationData = struct {
    apic_id: CpuId,
    lapic_addr: u32,
};

// NOTE: this struct is to serve as an accelerator
// to any core related query. It will be put in GS
// so that access to GS:0 would be the cpu_id (for example)
// TODO: move everything core related here
pub const CpuData = struct {
    id: CpuId,
    // add scheduling vars (current task, etc)
    // NOTE: Should contain all cpu related data
    // included in core CpuData struct
    // TSS, APIC controller
    apic_base_addr: u32,
    apic_id: CpuId,
    apic: *const Apic = undefined,

    pub fn init(cpu_id: CpuId, id_data: IdentificationData) CpuData {
        return .{
            .id = cpu_id,
            .apic_base_addr = id_data.lapic_addr,
            .apic_id = id_data.apic_id,
        };
    }
};

pub const CpuContext = cpu_debug_context.CpuContext;
pub const MSR = cpu_msr.MSR;
pub const Feature = cpu_features.Feature;
pub const CpuInfo = cpu_features.CpuInfo;

pub var cpu_info: CpuInfo = .{};

pub fn init() !void {
    try cpu_features.init(&cpu_info);
}

pub fn hasFeature(feature: Feature) bool {
    return cpu_info.flags.contains(feature);
}

pub fn doCpuChecks() !void {
    if (!hasFeature(.apic)) return error.NoApic;
}

pub fn initCore(cpu_id: CpuId) !void {
    flcn.cpu.cpu_data[cpu_id].apic = if (hasFeature(.x2apic)) &apic.x2apic.apic() else &apic.xapic.apic();
    assembly.wrmsr(.GS_BASE, @intFromPtr(&flcn.cpu.cpu_data[cpu_id]));
    try initLocalApic();
    flcn.cpu.cpu_data[cpu_id].apic.initLocalInterrupts(&smp.local_apic.nmis);
    flcn.cpu.cpu_data[cpu_id].apic.setEnabled(true);
}

pub fn initLocalApic() !void {
    if (hasFeature(.x2apic)) {
        try apic.x2apic.init();
    } else {
        try apic.xapic.init(smp.local_apic.address, &memory.kernel_vmem.impl);
    }
}

pub fn perCpu(comptime name: @TypeOf(.enum_literal)) @FieldType(CpuData, @tagName(name)) {
    const offset = @offsetOf(CpuData, @tagName(name));
    return asm volatile ("mov %gs:" ++ std.fmt.comptimePrint("{d}", .{offset}) ++ ", %[id]"
        : [id] "=r" (-> @FieldType(CpuData, @tagName(name))),
    );
}

pub fn TypeToPtr(comptime T: type, comptime mut: bool) type {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .pointer => |p| @Pointer(p.size, .{
            .@"const" = !mut,
            .@"addrspace" = p.address_space,
            .@"align" = p.alignment,
            .@"allowzero" = p.is_allowzero,
            .@"volatile" = p.is_volatile,
        }, T, p.sentinel()),
        .array => |a| @Pointer(.slice, .{ .@"const" = !mut }, T, a.sentinel()),
        else => @Pointer(.one, .{ .@"const" = !mut }, T, null),
    };
}

const PerCpuOptions = struct {
    mut: bool = false,
};

pub fn perCpuPtr(comptime name: @TypeOf(.enum_literal), comptime args: PerCpuOptions) TypeToPtr(@FieldType(CpuData, @tagName(name)), args.mut) {
    const offset = @offsetOf(CpuData, @tagName(name));
    const gs_base = assembly.rdmsr(.GS_BASE);
    return @ptrFromInt(gs_base + offset);
}
