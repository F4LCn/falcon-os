const std = @import("std");
const GDT = @import("descriptors/gdt.zig");
const options = @import("options");
const constants = @import("constants.zig");

const log = std.log.scoped(.descriptors);

var stacks: [options.max_cpu * constants.default_page_size]u8 align(constants.default_page_size) = [_]u8{0} ** (options.max_cpu * constants.default_page_size);

pub var gdt: GDT = undefined;

pub fn init() void {
    gdt = .create();
    gdt.fillGDTR();
    gdt.fillTss(&stacks);
    gdt.loadGDTR();
    gdt.loadTR(.{});
    gdt.flushGDT();
    log.info("segment descriptors initialized", .{});
}
