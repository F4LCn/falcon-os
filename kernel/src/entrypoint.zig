const options = @import("options");
const arch = @import("arch");

comptime {
    if (options.max_cpu <= 0) @compileError("No max_cpu set");
}

pub const std_options = arch.entrypoint.std_options;

export const _start = arch.entrypoint.start;
// export fn _start() callconv(.naked) noreturn {
//     @call(.always_inline, arch.entrypoint.start, .{});
//     // arch.entrypoint.start();
// }
