const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const constants = @import("constants");
const debug = @import("debug.zig");

const log = std.log.scoped(.@"************************* PANICC *************************");

pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    var stacktrace = debug.StackTrace{
        .addresses = .{0} ** 5,
    };
    if (constants.safety) {
        _ = stacktrace.capture(first_trace_addr orelse @returnAddress());
    }

    log.err(
        \\
        \\Kernel panicked with error: {s}
        \\Panic stack trace:
        \\{f}
    , .{ msg, stacktrace });
    log.err("", .{});

    arch.assembly.haltEternally();
}
