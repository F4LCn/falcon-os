const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch");
const options = @import("options");
const debug = @import("flcn").debug;

const log = std.log.scoped(.@"************************* PANICC *************************");

pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    var stacktrace = debug.StackTrace{
        .addresses = .{0} ** debug.StackTrace.num_traces,
    };
    if (options.safety) {
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
