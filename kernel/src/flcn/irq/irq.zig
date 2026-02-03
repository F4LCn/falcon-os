const std = @import("std");
const options = @import("options");
const arch = @import("arch");
const cpu = @import("../cpu.zig");
// this is arch specific
// for x64 we have:

const log = std.log.scoped(.irq);

pub const VectorId = arch.irq.VectorId;
pub const Kind = arch.irq.Kind;
pub const Domain = arch.irq.Domain;
pub const DomainDefinition = arch.irq.DomainDefinition;

pub const Source = struct {
    domain: ?Domain = null,
    vector: ?VectorId = null,
    kind: Kind,
};

// TODO: this can be simplified to just arch.InterruptBackend instead of (Backend: type) + generics
const Self = @This();
pub const Route = union(enum) {
    cpu: cpu.CpuId,
    cpu_set: std.bit_set.StaticBitSet(options.max_cpu),
    any: void,
};
pub const Config = struct {
    masked: bool = true,
    shared: bool = false,
};
pub const Handler = struct {
    const HandlerFn = *const fn (*const arch.interrupts.interrupt_context.Context, *anyopaque) bool;
    data: *anyopaque,
    handler_fn: HandlerFn,

    pub fn handle(self: *Handler, irq_context: *const arch.interrupts.interrupt_context.Context) bool {
        return self.handler_fn(irq_context, self.data);
    }
};
pub const Request = struct {
    source: Source,
    route: Route = .any,
    config: Config = .{},
    handler: Handler,
    name: []const u8 = "<unamed>",

    // TODO: init function(s)
};

pub const IrqHandle = struct {
    vector: VectorId,
    handler: u64,

    pub fn mask(self: IrqHandle) !void {
        _ = self; // autofix
    }
    pub fn unmask(self: IrqHandle) !void {
        _ = self; // autofix
    }
    pub fn release(self: IrqHandle) !void {
        _ = self; // autofix
    }
};

const VectorAllocator = struct {
    const DomainAllocator = struct {
        bitset: std.StaticBitSet(arch.irq.max_vector_count),
        start_vector: VectorId,
        // TODO: handle shared vectors tracking

        pub fn init(domain_definition: DomainDefinition) DomainAllocator {
            return .{
                .bitset = .initFull(),
                .start_vector = switch (domain_definition) {
                    .single => |v| v,
                    .range => |r| r.start,
                },
            };
        }
    };
    allocators: std.EnumMap(Domain, DomainAllocator),

    pub fn init() @This() {
        var map = std.EnumMap(Domain, DomainAllocator).init(.{});
        for (std.enums.values(Domain)) |domain| {
            const domain_definition = arch.irq.domain_definitions.get(domain).?;
            map.put(domain, DomainAllocator.init(domain_definition));
        }
        return .{
            .allocators = map,
        };
    }

    pub fn alloc(self: *@This(), in_domain: ?arch.irq.Domain, _: struct { shared: bool = false }) !VectorId {
        const domain = if (in_domain) |d| d else arch.irq.default_domain;
        var domain_allocator = self.allocators.getPtr(domain).?;
        const first_free = domain_allocator.bitset.findFirstSet();
        domain_allocator.bitset.unset(first_free);
        return @intCast(first_free + domain_allocator.start_vector);
    }

    pub fn allocSpecificVector(self: *@This(), vector: VectorId, _: struct { shared: bool = false }) !VectorId {
        const domain = try getVectorDomain(vector);
        var domain_allocator = self.allocators.getPtr(domain).?;
        const idx: usize = @as(usize, vector) - domain_allocator.start_vector;
        if (!domain_allocator.bitset.isSet(idx)) return error.AlreadyAllocated;
        domain_allocator.bitset.unset(idx);
        return vector;
    }

    pub fn free(self: *@This(), vector: VectorId) !void {
        const domain = try getVectorDomain(vector);
        var domain_allocator = self.allocators.getPtr(domain).?;
        const idx: usize = @as(usize, vector) - domain_allocator.start_vector;
        if (domain_allocator.bitset.isSet(idx)) return error.AlreadyFree;
        domain_allocator.bitset.set(idx);
    }

    fn getVectorDomain(vector: VectorId) !Domain {
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

const Backend = arch.irq;

backend: Backend,
vector_allocator: VectorAllocator,

pub fn init() !Self {
    return .{
        .backend = try Backend.init(),
        .vector_allocator = VectorAllocator.init(),
    };
}

// NOTE: maybe if we release all handlers for a given irq/vector we auto mask that vector
pub fn register(self: Self, irq_request: Request) !IrqHandle {
    // 1/ check which vector we need
    // 1.1/ if vector specified: allocate specific vector from domain or error (vector domain mismatch, vector is not shared and already registered)
    // 1.2/ allocate a vector from the domain or error
    const vector = blk: {
        if (irq_request.source.vector) |vec| {
            break :blk try self.vector_allocator.allocSpecificVector(irq_request.source.domain, vec, .{ .shared = irq_request.config.shared });
        } else {
            break :blk try self.vector_allocator.alloc(irq_request.source.domain, .{ .shared = irq_request.config.shared });
        }
    };
    // 2/ ask the backend to config the irq source with the vector
    try self.backend.configureSource(irq_request.source.kind, irq_request.route, vector);
    // 3/ register the handler
    const handler_id = try self.handlers.register(irq_request.handler, irq_request.config.shared, vector);
    // 4/ decide if we unmask the irq or not
    if (!irq_request.config.masked) {
        try self.unmask(vector);
    }

    return .{
        .vector = vector,
        .handler = handler_id,
    };
}

// NOTE: mask ALWAYS does a hardware mask (so irq will be masked for all handlers)
pub fn mask(self: Self, vector: VectorId) !void {
    try self.backend.mask(vector);
}

// NOTE: unmask ALWAYS does a hardware mask (so irq will be unmasked for all handlers, BEWARE)
pub fn unmask(self: Self, vector: VectorId) !void {
    try self.backend.unmask(vector);
}

pub fn release(self: Self, vector: VectorId, handler: u64) !void {
    try self.handlers.release(handler);
    try self.backend.releaseSource(vector);
    try self.vector_allocator.free(vector);
}
