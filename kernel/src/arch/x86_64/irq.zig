const std = @import("std");
const flcn = @import("flcn");
const constants = @import("constants.zig");
const cpu = @import("cpu.zig");
const interrupts = @import("interrupts.zig");
const apic_types = @import("apic/types.zig");
const ioapic = @import("ioapic.zig");
const irq = flcn.irq.irq;
const irq_types = flcn.irq.types;

pub const Polarity = irq_types.Polarity;
pub const TriggerMode = irq_types.TriggerMode;

pub const VectorId = u8;
pub const vector_count = constants.max_interrupt_vectors;
pub const LocalApicInterrupt = apic_types.LocalInterrupt;
pub const LocalApicSource = struct {
    interrupt: LocalApicInterrupt,
    polarity: Polarity,
    trigger_mode: TriggerMode,
};

pub const Kind = union(enum) {
    fixed,
    ioapic: struct {
        gsi: u32,
        polarity: Polarity = .active_high,
        trigger_mode: TriggerMode = .edge_triggered,
    },
    local_apic: LocalApicSource,
    msi,
};

// domains
// [32 -> 254] -> dynamic irq
// [0 - 31] -> system fixed domain
// [255] -> spurious irq
pub const Domain = enum {
    dynamic,
    system,
    spurious,
};
pub const DomainDefinition = union(enum) {
    single: VectorId,
    range: struct {
        start: VectorId,
        end: VectorId,
    },

    pub fn contains(self: DomainDefinition, vector: VectorId) bool {
        return switch (self) {
            .single => |v| v == vector,
            .range => |r| r.start <= vector and vector <= r.end,
        };
    }
};
// TODO: add a comptime check that goes through the map and checks that domains don't overlap
pub const domain_definitions: std.EnumMap(Domain, DomainDefinition) = .init(.{
    .system = .{
        .range = .{ .start = 0, .end = 31 },
    },
    .dynamic = .{
        .range = .{ .start = 32, .end = 254 },
    },
    .spurious = .{
        .single = 255,
    },
});
pub const default_domain: Domain = .dynamic;

const Self = @This();

const SourceRecord = struct {
    kind: Kind,
    route: irq.Route,
    masked: bool,
};

sources: [vector_count]?SourceRecord = .{null} ** vector_count,

pub fn init() !Self {
    return .{};
}

pub fn initSystemExceptions(self: *Self, manager: *irq.Manager) !void {
    for (0..interrupts.system_interrupt_count) |vector_index| {
        const vector: VectorId = @intCast(vector_index);
        _ = try manager.registerReservedVector(.{
            .source = .{
                .domain = .system,
                .vector = vector,
                .kind = .fixed,
            },
            .config = .{ .masked = false },
            .handler = .{
                .handler_fn = interrupts.defaultExceptionIrqHandler,
            },
            .name = interrupts.vectorToName(vector),
        });
    }
    _ = self;
}

pub fn configureSource(self: *Self, kind: Kind, route: irq.Route, vector: VectorId, masked: bool) !void {
    const source_record = SourceRecord{
        .kind = kind,
        .route = route,
        .masked = masked,
    };
    switch (kind) {
        .fixed => {},
        .ioapic => |source| try ioapic.configure(.{
            .gsi = source.gsi,
            .vector = vector,
            .target_cpu = try resolveTargetCpu(route),
            .masked = masked,
            .polarity = toIoApicPolarity(source.polarity),
            .trigger_mode = toIoApicTriggerMode(source.trigger_mode),
        }),
        .local_apic => |source| try configureLocalApic(source, route, vector, masked),
        .msi => return error.UnsupportedIrqSource,
    }
    self.sources[vector] = source_record;
}

pub fn mask(self: *Self, vector: VectorId) !void {
    const source = self.sources[vector] orelse return error.UnconfiguredIrqSource;
    switch (source.kind) {
        .fixed => {},
        .ioapic => |ioapic_source| try ioapic.mask(ioapic_source.gsi),
        .local_apic => |local_apic_source| try cpu.perCpu(.apic).mask(local_apic_source.interrupt),
        .msi => return error.UnsupportedIrqSource,
    }
    self.sources[vector].?.masked = true;
}

pub fn unmask(self: *Self, vector: VectorId) !void {
    const source = self.sources[vector] orelse return error.UnconfiguredIrqSource;
    switch (source.kind) {
        .fixed => {},
        .ioapic => |ioapic_source| try ioapic.unmask(ioapic_source.gsi),
        .local_apic => |local_apic_source| try cpu.perCpu(.apic).unmask(local_apic_source.interrupt),
        .msi => return error.UnsupportedIrqSource,
    }
    self.sources[vector].?.masked = false;
}

pub fn setRoute(self: *Self, vector: VectorId, route: irq.Route) !void {
    const source = self.sources[vector] orelse return error.UnconfiguredIrqSource;
    const target_cpu = try resolveTargetCpu(route);
    switch (source.kind) {
        .fixed => {},
        .ioapic => |ioapic_source| try ioapic.route(ioapic_source.gsi, target_cpu),
        .local_apic => try ensureLocalApicTarget(target_cpu),
        .msi => return error.UnsupportedIrqSource,
    }
    self.sources[vector].?.route = route;
}

pub fn releaseSource(self: *Self, vector: VectorId) !void {
    const source = self.sources[vector] orelse return;
    switch (source.kind) {
        .fixed => {},
        .ioapic => |ioapic_source| try ioapic.mask(ioapic_source.gsi),
        .local_apic => |local_apic_source| try cpu.perCpu(.apic).mask(local_apic_source.interrupt),
        .msi => return error.UnsupportedIrqSource,
    }
    self.sources[vector] = null;
}

pub fn eoi(self: *Self, vector: VectorId) void {
    const source = self.sources[vector] orelse return;
    switch (source.kind) {
        .fixed => {},
        .ioapic, .local_apic, .msi => cpu.perCpu(.apic).eoi(),
    }
}

fn resolveTargetCpu(route: irq.Route) !cpu.CpuId {
    return switch (route) {
        .cpu => |cpu_id| cpu_id,
        .any => 0,
        .cpu_set => |cpu_set| chooseCpuFromSet(cpu_set),
    };
}

fn chooseCpuFromSet(cpu_set: std.bit_set.StaticBitSet(flcn.cpu.possible_cpus_count)) !cpu.CpuId {
    // TODO: choose least-busy CPU from the set once scheduler/idle-time accounting exists.
    return @intCast(cpu_set.findFirstSet() orelse return error.EmptyCpuSet);
}

fn configureLocalApic(source: LocalApicSource, route: irq.Route, vector: VectorId, masked: bool) !void {
    try ensureLocalApicTarget(try resolveTargetCpu(route));
    try cpu.perCpu(.apic).configure(source.interrupt, .{
        .vector = vector,
        .masked = masked,
        .polarity = toLocalApicPolarity(source.polarity),
        .trigger_mode = toLocalApicTriggerMode(source.trigger_mode),
    });
}

fn ensureLocalApicTarget(target_cpu: cpu.CpuId) !void {
    if (target_cpu != cpu.perCpu(.id)) return error.UnsupportedRemoteLocalApicRoute;
}

fn toIoApicPolarity(polarity: Polarity) ioapic.Polarity {
    return switch (polarity) {
        .active_high => .active_high,
        .active_low => .active_low,
    };
}

fn toIoApicTriggerMode(trigger_mode: TriggerMode) ioapic.TriggerMode {
    return switch (trigger_mode) {
        .edge_triggered => .edge_triggered,
        .level_triggered => .level_triggered,
    };
}

fn toLocalApicPolarity(polarity: Polarity) apic_types.Polarity {
    return switch (polarity) {
        .active_high => .active_high,
        .active_low => .active_low,
    };
}

fn toLocalApicTriggerMode(trigger_mode: TriggerMode) apic_types.TriggerMode {
    return switch (trigger_mode) {
        .edge_triggered => .edge_triggered,
        .level_triggered => .level_triggered,
    };
}
