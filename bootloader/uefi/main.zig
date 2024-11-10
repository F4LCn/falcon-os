const std = @import("std");
const uefi = std.os.uefi;
const serial = @import("serial.zig");
const logger = @import("logger.zig");
const Globals = @import("globals.zig");
const BootInfo = @import("bootinfo.zig").BootInfo;
const Config = @import("config.zig");
const Video = @import("video.zig");
const FileSystem = @import("fs.zig");
const Mmap = @import("mmap.zig");
const KernelLoader = @import("kernel_loader.zig");
const Constants = @import("constants.zig");
const AddressSpace = @import("address_space.zig");
const BootloaderError = @import("errors.zig").BootloaderError;
const MemHelper = @import("mem_helper.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};

pub fn main() uefi.Status {
    logger.init(serial.Port.COM1);
    Globals.init();
    FileSystem.init() catch {
        std.log.err("Failed to initialize filesystem subsystem", .{});
        return uefi.Status.Aborted;
    };
    Video.init();

    const bootinfo_page = MemHelper.allocatePages(1) catch {
        std.log.err("Could not allocate a page for bootinfo struct", .{});
        return uefi.Status.Aborted;
    };
    var bootinfo: *align(Constants.ARCH_PAGE_SIZE) BootInfo = @ptrCast(bootinfo_page);
    bootinfo.* = .{
        .bootloader_type = .UEFI,
        .mmap = .{
            .ptr = 0xABABABAB,
            .size = 12345,
        },
    };

    const config = FileSystem.loadFile("/SYS/KERNEL.CON") catch {
        std.log.err("Failed to load config file", .{});
        return uefi.Status.Aborted;
    };
    std.log.debug(
        \\Got config:
        \\{s}"
    , .{config.getContents()});

    const bootloader_config = Config.parseConfig(config.getContents()) catch {
        std.log.err("Failed to parse config", .{});
        return uefi.Status.Aborted;
    };
    std.log.info(
        \\Parsed config file
        \\Kernel file: {s}
        \\Video resolution: {d} x {d}"
    , .{
        bootloader_config.kernel,
        bootloader_config.video.width,
        bootloader_config.video.height,
    });

    const video_info: Video.VideoInfo = Video.getPreferredResolution() catch blk: {
        std.log.warn("Could not resolve display preferred resolution, falling back on config", .{});
        break :blk .{ .device_handle = null, .resolution = bootloader_config.video };
    };

    std.log.info("Using resolution {d}x{d}", .{
        video_info.resolution.width,
        video_info.resolution.height,
    });

    Video.getFramebuffer(video_info, bootinfo) catch {
        std.log.err("Could not set video mode", .{});
        return uefi.Status.Aborted;
    };
    Video.fillRect(255, 8, 4) catch {
        std.log.err("FillRect failed", .{});
        return uefi.Status.Aborted;
    };

    std.log.debug("Bootinfo struct: {any}", .{bootinfo});

    const kernel = FileSystem.loadFile(bootloader_config.kernel) catch {
        std.log.err("Could not load kernel file", .{});
        return uefi.Status.Aborted;
    };
    _ = &kernel;

    const kernel_info = KernelLoader.loadExecutable(kernel.getContents()) catch {
        std.log.err("Could not load kernel executable", .{});
        return uefi.Status.Aborted;
    };

    var addr_space = AddressSpace.create() catch {
        std.log.err("Could not create address space", .{});
        return uefi.Status.Aborted;
    };

    const fb_ptr = bootinfo.fb_ptr;
    const fb_size = (@as(u64, bootinfo.fb_height)) * (@as(u64, bootinfo.fb_scanline_bytes));
    mapKernelSpace(&addr_space, kernel_info, @intFromPtr(bootinfo), fb_ptr, fb_size, @intFromPtr(config.buffer.ptr)) catch {
        std.log.err("Could not map kernel address space", .{});
        return uefi.Status.Aborted;
    };

    addr_space.print();

    std.log.debug("bootinfo page: {X}", .{bootinfo_page[0..200]});

    const mmap_entries: [*]BootInfo.MmapEntry = @ptrCast(&bootinfo.mmap);
    Mmap.getMemMap(bootinfo) catch |e| {
        std.log.err("Failed to get memory map. Error: {}", .{e});
        std.log.err("mmap: ", .{});
        for (mmap_entries[0..5], 0..) |entry, i| {
            std.log.err("[{d}] entry: Start=0x{X} Size=0x{X} Typ={}", .{ i, entry.getPtr(), entry.getSize(), entry.getType() });
        }
        return uefi.Status.Aborted;
    };
    for (mmap_entries[0..20], 0..) |entry, i| {
        std.log.err("[{d}] entry: Start=0x{X} Size=0x{X} Typ={}", .{ i, entry.getPtr(), entry.getSize(), entry.getType() });
    }

    const conin = Globals.sys_table.con_in.?;
    const input_events = [_]uefi.Event{
        conin.wait_for_key,
    };

    var index: usize = undefined;
    while (Globals.boot_services.waitForEvent(input_events.len, &input_events, &index) == uefi.Status.Success) {
        if (index == 0) {
            var input_key: uefi.protocol.SimpleTextInputEx.Key.Input = undefined;
            if (conin.readKeyStroke(&input_key) == uefi.Status.Success) {
                if (input_key.unicode_char == @as(u16, 'Q')) {
                    return uefi.Status.Success;
                }
            }
        }
    }

    return uefi.Status.Timeout;
}

fn mapKernelSpace(
    addr_space: *AddressSpace,
    kernel_info: *const KernelLoader.KernelInfo,
    bootinfo_ptr: u64,
    fb_ptr: u64,
    fb_size: u64,
    env_ptr: u64,
) BootloaderError!void {
    const log = std.log.scoped(.KernelSpaceMapper);
    // core stack
    var core_stack_vaddr: u64 = @bitCast(@as(i64, -Constants.ARCH_PAGE_SIZE));
    for (0..Constants.MAX_CPU) |i| {
        const core_stack_ptr = try MemHelper.allocatePages(1);
        log.debug("Mapping core[{d}] stack: 0x{X} -> 0x{X}", .{ i, @intFromPtr(core_stack_ptr), core_stack_vaddr });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(core_stack_vaddr) },
            .{ .paddr = @intFromPtr(core_stack_ptr) },
            AddressSpace.DefaultMmapFlags,
        );
        core_stack_vaddr -= Constants.ARCH_PAGE_SIZE;
    }
    // kernel
    for (0..kernel_info.segment_count) |idx| {
        const mapping = &kernel_info.segment_mappings[idx];
        log.debug("kernel segment: {any}", .{mapping});
        var mapping_vaddr = switch (mapping.vaddr) {
            .vaddr => |x| @as(u64, @bitCast(x)),
            else => unreachable,
        };
        var mapping_paddr = switch (mapping.paddr) {
            .paddr => |x| @as(u64, @bitCast(x)),
            else => unreachable,
        };
        log.debug("Mapping kernel segment 0x{X} -> 0x{X}", .{
            @as(u64, @bitCast(mapping_paddr)),
            @as(u64, @bitCast(mapping_vaddr)),
        });
        const num_pages = ((mapping.len + Constants.ARCH_PAGE_SIZE - 1) / Constants.ARCH_PAGE_SIZE);
        for (0..num_pages) |p| {
            mapping_paddr += Constants.ARCH_PAGE_SIZE;
            mapping_vaddr += Constants.ARCH_PAGE_SIZE;
            log.debug("\t kernel segment[{d}] 0x{X} -> 0x{X}", .{
                p,
                @as(u64, @bitCast(mapping_paddr)),
                @as(u64, @bitCast(mapping_vaddr)),
            });
            try addr_space.mmap(
                .{ .vaddr = @bitCast(mapping_vaddr) },
                .{ .paddr = mapping_paddr },
                AddressSpace.DefaultMmapFlags,
            );
        }
    }
    // bootinfo
    if (kernel_info.bootinfo_addr) |bootinfo_addr| {
        log.debug("Mapping bootinfo struct 0x{X} -> 0x{X}", .{ bootinfo_ptr, bootinfo_addr });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(bootinfo_addr) },
            .{ .paddr = bootinfo_ptr },
            AddressSpace.DefaultMmapFlags,
        );
    }
    // fb
    // TODO: make sure the size is page aligned
    if (kernel_info.fb_addr) |fb_addr| {
        log.debug("Mapping framebuffer from 0x{X} -> 0x{X} (0x{X})", .{ fb_ptr, fb_addr, fb_size });
        var fb_vaddr = fb_addr;
        var fb_paddr = fb_ptr;
        while (fb_paddr < fb_ptr + fb_size) : ({
            fb_paddr += Constants.ARCH_PAGE_SIZE;
            fb_vaddr += Constants.ARCH_PAGE_SIZE;
        }) {
            try addr_space.mmap(
                .{ .vaddr = @bitCast(fb_vaddr) },
                .{ .paddr = fb_paddr },
                AddressSpace.DefaultMmapFlags,
            );
        }
    }
    // env
    if (kernel_info.env_addr) |env_addr| {
        log.debug("Mapping env 0x{X} -> 0x{X}", .{ env_ptr, env_addr });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(env_addr) },
            .{ .paddr = env_ptr },
            AddressSpace.DefaultMmapFlags,
        );
    }
    // Identity mapping
    var i: u64 = 0;
    while (i < MemHelper.mb(64)) : (i += Constants.ARCH_PAGE_SIZE) {
        try addr_space.mmap(
            .{ .vaddr = @bitCast(i) },
            .{ .paddr = @bitCast(i) },
            AddressSpace.DefaultMmapFlags,
        );
    }
}
