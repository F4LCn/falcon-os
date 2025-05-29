const pmem = @import("memory/pmem.zig");
const vmem = @import("memory/vmem.zig");

const buddy = @import("memory/buddy.zig");
// NOTE: this module is the entrypoint to everything memory related
// TODO: move all functionality that interact between pmem and vmem here


test {
    _ = @import("memory/pmem.zig");
    _ = @import("memory/vmem.zig");
    _ = @import("memory/buddy.zig");
}
