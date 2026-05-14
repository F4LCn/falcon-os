const std = @import("std");
const options = @import("options");
const arch = @import("arch");
const cpu = @import("../cpu.zig");
const types = @import("types.zig");

pub const log = std.log.scoped(.irq);

pub const VectorId = arch.irq.VectorId;
pub const Kind = arch.irq.Kind;
pub const Domain = arch.irq.Domain;
pub const DomainDefinition = arch.irq.DomainDefinition;
pub const Polarity = types.Polarity;
pub const TriggerMode = types.TriggerMode;

pub const Source = struct {
    domain: ?Domain = null,
    vector: ?VectorId = null,
    kind: Kind,
};

const Self = @This();
pub const Manager = Self;

pub const VectorMetrics = struct {
    interrupt_count: u64 = 0,
    total_handler_time: u64 = 0,
    max_handler_time: u64 = 0,
    last_handler_time: u64 = 0,
    last_cpu: ?cpu.CpuId = null,
};

pub const CpuVectorMetrics = struct {
    interrupt_count: u64 = 0,
    total_handler_time: u64 = 0,
    max_handler_time: u64 = 0,
    last_handler_time: u64 = 0,
};

pub const CpuMetrics = struct {
    total_interrupt_count: u64 = 0,
    total_handler_time: u64 = 0,
    max_handler_time: u64 = 0,
    per_vector: [arch.irq.vector_count]CpuVectorMetrics = [_]CpuVectorMetrics{.{}} ** arch.irq.vector_count,
};

pub const Metrics = struct {
    per_vector: [arch.irq.vector_count]VectorMetrics = [_]VectorMetrics{.{}} ** arch.irq.vector_count,
    per_cpu: [cpu.possible_cpus_count]CpuMetrics = [_]CpuMetrics{.{}} ** cpu.possible_cpus_count,

    pub fn recordInterrupt(self: *@This(), vector: VectorId) void {
        if (!options.irq_metrics) @panic("IRQ metrics disabled");

        const cpu_id = cpu.perCpu(.id);
        const cpu_metrics = &self.per_cpu[cpu_id];

        self.per_vector[vector].interrupt_count += 1;
        self.per_vector[vector].last_cpu = cpu_id;

        cpu_metrics.total_interrupt_count += 1;
        cpu_metrics.per_vector[vector].interrupt_count += 1;
    }
};

pub const Route = union(enum) {
    cpu: cpu.CpuId,
    cpu_set: std.bit_set.StaticBitSet(options.max_cpu),
    any: void,
};
pub const Config = struct {
    masked: bool = true,
};
pub const Handler = struct {
    const HandlerFn = *const fn (*const arch.interrupts.interrupt_context.Context, ?*anyopaque) void;
    data: ?*anyopaque = null,
    handler_fn: HandlerFn,

    pub fn handle(self: *Handler, irq_context: *const arch.interrupts.interrupt_context.Context) void {
        self.handler_fn(irq_context, self.data);
    }
};
pub const Request = struct {
    source: Source,
    route: Route = .any,
    config: Config = .{},
    handler: Handler,
    name: []const u8 = "<unnamed>",
};

pub const IrqHandle = struct {
    vector: VectorId,
};

const VectorAllocator = struct {
    const VectorState = enum {
        free,
        reserved,
        allocated,
    };

    const VectorDebug = if (options.irq_debug) struct {
        name: []const u8 = "",
        allocation_count: u64 = 0,
        free_count: u64 = 0,
    } else void;

    const VectorRecord = struct {
        state: VectorState = .reserved,
        domain: Domain,
        debug: VectorDebug = if (options.irq_debug) .{} else {},
    };

    const SpecificAllocOptions = struct {
        domain: ?Domain = null,
        allow_reserved: bool = false,
    };

    records: [arch.irq.vector_count]VectorRecord,

    pub fn init() @This() {
        var records: [arch.irq.vector_count]VectorRecord = undefined;
        for (&records, 0..) |*record, index| {
            const vector: VectorId = @intCast(index);
            const domain = domainOf(vector) catch unreachable;
            record.* = .{
                .state = if (domain == arch.irq.default_domain) .free else .reserved,
                .domain = domain,
            };
        }
        return .{
            .records = records,
        };
    }

    pub fn alloc(self: *@This(), in_domain: ?arch.irq.Domain) !VectorId {
        const domain = if (in_domain) |d| d else arch.irq.default_domain;
        for (&self.records, 0..) |*record, index| {
            if (record.domain != domain or record.state != .free) continue;
            record.state = .allocated;
            if (options.irq_debug) record.debug.allocation_count += 1;
            return @intCast(index);
        }
        return error.NoFreeVector;
    }

    pub fn allocSpecificVector(self: *@This(), vector: VectorId, options_: SpecificAllocOptions) !VectorId {
        const domain = try domainOf(vector);
        if (options_.domain) |expected_domain| {
            if (expected_domain != domain) return error.VectorDomainMismatch;
        }
        const record = &self.records[vector];
        switch (record.state) {
            .free => {},
            .reserved => if (!options_.allow_reserved) return error.ReservedVector,
            .allocated => return error.AlreadyAllocated,
        }
        record.state = .allocated;
        if (options.irq_debug) record.debug.allocation_count += 1;
        return vector;
    }

    pub fn free(self: *@This(), vector: VectorId) !void {
        const domain = try domainOf(vector);
        const record = &self.records[vector];
        if (record.state != .allocated) return error.AlreadyFree;
        record.state = if (domain == arch.irq.default_domain) .free else .reserved;
        if (options.irq_debug) record.debug.free_count += 1;
    }

    pub fn domainOf(vector: VectorId) !Domain {
        const domains = std.enums.values(Domain);
        const domain: Domain = blk: for (domains) |domain| {
            const domain_definition = arch.irq.domain_definitions.get(domain).?;
            if (!domain_definition.contains(vector)) continue;
            break :blk domain;
        } else {
            return error.NoDomain;
        };
        return domain;
    }
};

const IrqRecord = struct {
    handler: ?Handler = null,
    route: Route = .any,
    masked: bool = true,
    name: []const u8 = "",
};

const RegisterOptions = struct {
    allow_reserved_vector: bool = false,
};

const Backend = arch.irq;
const Context = arch.interrupts.interrupt_context.Context;

backend: Backend,
vector_allocator: VectorAllocator,
records: [arch.irq.vector_count]IrqRecord,
metrics: Metrics,

pub fn init() !Self {
    return .{
        .backend = try Backend.init(),
        .vector_allocator = VectorAllocator.init(),
        .records = [_]IrqRecord{.{}} ** arch.irq.vector_count,
        .metrics = .{},
    };
}

pub fn register(self: *Self, irq_request: Request) !IrqHandle {
    return try self.registerWithOptions(irq_request, .{});
}

pub fn registerReservedVector(self: *Self, irq_request: Request) !IrqHandle {
    return try self.registerWithOptions(irq_request, .{ .allow_reserved_vector = true });
}

fn registerWithOptions(self: *Self, irq_request: Request, register_options: RegisterOptions) !IrqHandle {
    const vector = blk: {
        if (irq_request.source.vector) |vec| {
            break :blk try self.vector_allocator.allocSpecificVector(vec, .{
                .domain = irq_request.source.domain,
                .allow_reserved = register_options.allow_reserved_vector,
            });
        } else {
            break :blk try self.vector_allocator.alloc(irq_request.source.domain);
        }
    };
    errdefer self.vector_allocator.free(vector) catch {};
    if (self.records[vector].handler != null) return error.IrqHandlerAlreadyRegistered;
    try self.backend.configureSource(irq_request.source.kind, irq_request.route, vector, irq_request.config.masked);
    errdefer self.backend.releaseSource(vector) catch {};
    self.records[vector] = .{
        .handler = irq_request.handler,
        .route = irq_request.route,
        .masked = irq_request.config.masked,
        .name = irq_request.name,
    };
    if (options.irq_debug) self.vector_allocator.records[vector].debug.name = irq_request.name;
    if (!irq_request.config.masked) {
        try self.unmask(vector);
    }

    return .{
        .vector = vector,
    };
}

pub fn mask(self: *Self, vector: VectorId) !void {
    try self.backend.mask(vector);
    self.records[vector].masked = true;
}

pub fn unmask(self: *Self, vector: VectorId) !void {
    try self.backend.unmask(vector);
    self.records[vector].masked = false;
}

pub fn setRoute(self: *Self, vector: VectorId, route: Route) !void {
    try self.backend.setRoute(vector, route);
    self.records[vector].route = route;
}

pub fn release(self: *Self, vector: VectorId) !void {
    self.records[vector] = .{};
    try self.backend.releaseSource(vector);
    try self.vector_allocator.free(vector);
}

pub fn dispatchContext(self: *Self, context: *Context) bool {
    const vector: VectorId = std.math.cast(VectorId, context.vector) orelse return false;
    var record = &self.records[vector];
    if (record.handler) |*handler| {
        handler.handle(context);
        if (options.irq_metrics) self.metrics.recordInterrupt(vector);
        self.backend.eoi(vector);
        return true;
    }
    return false;
}
