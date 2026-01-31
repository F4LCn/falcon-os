const std = @import("std");
const options = @import("options");
const arch = @import("arch");
const cpu = @import("../cpu.zig");
// this is arch specific
// for x64 we have:

// domains
// [0 - 31] -> system fixed domain
// [32 -> 254] -> dynamic irq
// [255] -> spurious irq
pub const VectorId = u8;
pub const Domain = union(enum) {
    single: VectorId,
    range: struct {
        start: VectorId,
        end: VectorId,
    },
};
pub const Source = struct {
    domain: ?Domain = null,
    vector: ?VectorId = null,
    kind: union(enum) {
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
    },
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

    pub fn mask(self: IrqHandle) !void {}
    pub fn unmask(self: IrqHandle) !void {}
    pub fn release(self: IrqHandle) !void {}
};

const Backend = arch.InterruptBackend;

backend: Backend,
vector_allocator: VectorAllocator,

pub fn init() !Self {
    return .{
        .backend = Backend.init(),
        .vector_allocator = VectorAllocator.init(), // NOTE: will need to know about the domains, and the default domain
    };
}

// NOTE: maybe if we release all handlers for a given irq/vector we auto mask that vector
pub fn register(self: Self, irq_request: Request) !IrqHandle {
    _ = irq_request;
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
