const constants = @import("constants");

pub fn validate() void {
    if (constants.max_cpu <= 0)
        @compileError("No max_cpu set");
}
