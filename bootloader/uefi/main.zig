const std = @import("std");
const uefi = std.os.uefi;
const serial = @import("serial.zig");
const logger = @import("logger.zig");
const Globals = @import("globals.zig");
const BootInfo = @import("bootinfo.zig");
const Config = @import("config.zig");
const Video = @import("video.zig");
const FileSystem = @import("fs.zig");
const Mmap = @import("mmap.zig");
const KernelLoader = @import("kernel_loader.zig");
const Constants = @import("constants.zig");
const AddressSpace = @import("address_space.zig");

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

    var bootinfo: *align(Constants.ARCH_PAGE_SIZE) BootInfo = undefined;
    const status = Globals.boot_services.allocatePages(.AllocateAnyPages, .LoaderData, 1, @ptrCast(&bootinfo));
    switch (status) {
        .Success => std.log.debug("Allocated 1 page for bootinfo struct", .{}),
        else => {
            std.log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return uefi.Status.Aborted;
        },
    }
    bootinfo.* = .{ .bootloader_type = .UEFI };

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
    _ = &kernel_info;

    const addr_space = AddressSpace.create() catch {
        std.log.err("Could not create address space", .{});
        return uefi.Status.Aborted;
    };

    for (0..10) |i| {
        const paddr = 0xC012345000 + i * Constants.ARCH_PAGE_SIZE;
        const vaddr = 0xC054321000 + i * Constants.ARCH_PAGE_SIZE;
        addr_space.mmap(.{ .vaddr = @bitCast(vaddr) }, .{ .paddr = @intCast(paddr) }, .{ .present = true, .read_write = .read_write }) catch {
            std.log.warn("Could not map vaddr 0x{X} to paddr 0x{X}", .{ vaddr, paddr });
            continue;
        };
    }

    for (0..10) |i| {
        const paddr = 0x1234000 + i * Constants.ARCH_PAGE_SIZE;
        const vaddr = 0x4321000 + i * Constants.ARCH_PAGE_SIZE;
        addr_space.mmap(.{ .vaddr = @bitCast(vaddr) }, .{ .paddr = @intCast(paddr) }, .{ .present = true, .read_write = .read_write }) catch {
            std.log.warn("Could not map vaddr 0x{X} to paddr 0x{X}", .{ vaddr, paddr });
            continue;
        };
    }
    addr_space.print();

    // Mmap.getMemMap(bootinfo) catch {
    //     std.log.err("Failed to get memory map", .{});
    //     return uefi.Status.Aborted;
    // };

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
