const constants = @import("constants");

pub fn validate() void {
    if (constants.arch_page_size <= 0)
        @compileError("No page size specified for arch " ++ @tagName(constants.arch));
    if (constants.max_cpu <= 0)
        @compileError("No max_cpu set");
}
