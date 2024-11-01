const std = @import("std");
const BootloaderError = @import("errors.zig").BootloaderError;
const Constants = @import("constants.zig");
const Globals = @import("globals.zig");

const log = std.log.scoped(.MemHelper);

pub fn kb(val: comptime_int) comptime_int {
    return val * 1024;
}

pub fn mb(val: comptime_int) comptime_int {
    return kb(val) * 1024;
}

pub fn allocatePages(num_pages: u64) BootloaderError![*]align(Constants.ARCH_PAGE_SIZE) u8 {
    var page_ptr: [*]align(Constants.ARCH_PAGE_SIZE) u8 = undefined;
    const status = Globals.boot_services.allocatePages(.AllocateAnyPages, .LoaderData, num_pages, &page_ptr);
    switch (status) {
        .Success => log.debug("Allocated {d} pages at 0x{X}", .{ num_pages, @intFromPtr(page_ptr) }),
        else => return BootloaderError.AddressSpaceAllocatePages,
    }
    @memset(page_ptr[0 .. num_pages * Constants.ARCH_PAGE_SIZE], 0);
    return page_ptr;
}
