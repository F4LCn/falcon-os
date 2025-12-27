const options = @import("options");
const arch = @import("arch");
pub const debug = @import("debug.zig");

comptime {
    if (options.max_cpu == 0) @compileError("No max_cpu set");
}

pub const panic = arch.entrypoint.panic;
pub const std_options = arch.entrypoint.std_options;
export const _start = arch.entrypoint.start;
