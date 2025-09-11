const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const constants = @import("constants");
const debug = @import("debug.zig");

const log = std.log.scoped(.panic);
pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    var stack_trace = std.builtin.StackTrace{
        .instruction_addresses = &.{},
        .index = 0,
    };
    if (constants.safety and first_trace_addr != null) {
        var addresses: [constants.num_stack_trace]usize = .{0} ** constants.num_stack_trace;
        stack_trace.instruction_addresses = &addresses;
        std.debug.captureStackTrace(first_trace_addr, &stack_trace);
    }

    log.err("************************* PANICC *************************", .{});
    log.err("Kernel panicked with error: {s}", .{msg});
    log.err("Panic stack trace:", .{});

    const stack_trace_len = @min(stack_trace.index, stack_trace.instruction_addresses.len);
    for (stack_trace.instruction_addresses[0..stack_trace_len], 0..) |address, idx| {
        log.err("[frame#{d:>3}]: 0x{x}", .{ idx, address });
    }

    log.err("************************* PANICC *************************", .{});

    arch.assembly.haltEternally();
}
