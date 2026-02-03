const std = @import("std");
const flcn = @import("flcn");
const irq = flcn.irq;

pub const Polarity = struct {};
pub const TriggerMode = struct {};

pub const VectorId = u8;
pub const max_vector_count = std.math.maxInt(VectorId);
pub const Kind = union(enum) {
    fixed,
    ioapic: struct {
        polarity: Polarity,
        trigger_mode: TriggerMode,
        // ...
    },
    local_apic: struct {
        polarity: Polarity,
        trigger_mode: TriggerMode,
        // ...
    },
    msi: struct {
        // TODO: if we ever get to pci this needs to be implemented
    },
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

pub fn init() !Self {
    return .{};
}

pub fn configureSource(self: Self, kind: Kind, route: irq.Route, vector: VectorId) !void {
    _ = self; // autofix
    _ = kind; // autofix
    _ = route; // autofix
    _ = vector; // autofix
}

pub fn mask(self: Self, vector: VectorId) !void {
    _ = self; // autofix
    _ = vector; // autofix
}

pub fn unmask(self: Self, vector: VectorId) !void {
    _ = self; // autofix
    _ = vector; // autofix
}

pub fn releaseSource(self: Self, vector: VectorId) !void {
    _ = self; // autofix
    _ = vector; // autofix
}
