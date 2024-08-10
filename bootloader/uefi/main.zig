const std = @import("std");
const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;
const serial = @import("serial.zig");
const logger = @import("logger.zig");
const BootInfo = @import("bootinfo.zig").BootInfo;

const BootloaderError = error{
    MemoryMapError,
    ConfigFileLoadError,
    ConfigFileParseError,
    GraphicOutputDeviceError,
    LocateGraphicOutputError,
    EdidNotFoundError,
};

const VideoResolution = struct { width: u16, height: u16 };
const VideoInfo = struct { device_handle: ?uefi.Handle, resolution: VideoResolution };

const BootloaderConfig = struct {
    kernel: []const u8 = "",
    video: VideoResolution = .{ .width = 640, .height = 480 },
};

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};

pub fn main() uefi.Status {
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;

    logger.init(serial.Port.COM1);

    const config = readConfigFile() catch {
        std.log.err("Failed to get memory map", .{});
        return uefi.Status.Aborted;
    };
    std.log.debug(
        \\Got config:
        \\{s}"
    , .{config});

    const bootloader_config = parseConfig(config) catch {
        std.log.err("Failed to get memory map", .{});
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

    const video_info: VideoInfo = getPreferredResolution() catch blk: {
        std.log.warn("Could not resolve display preferred resolution, falling back on config", .{});
        break :blk .{ .device_handle = null, .resolution = bootloader_config.video };
    };
    std.log.info("Using resolution {d}x{d}", .{
        video_info.resolution.width,
        video_info.resolution.height,
    });

    getFramebuffer(video_info) catch {
        std.log.err("Could not set video mode", .{});
        return uefi.Status.Aborted;
    };

    getMemMap() catch {
        std.log.err("Failed to get memory map", .{});
        return uefi.Status.Aborted;
    };

    const conin = sys_table.con_in.?;
    const input_events = [_]uefi.Event{
        conin.wait_for_key,
    };

    var index: usize = undefined;
    while (boot_services.waitForEvent(input_events.len, &input_events, &index) == uefi.Status.Success) {
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

fn getFramebuffer(video_info: VideoInfo) BootloaderError!void {
    const log = std.log.scoped(.video_mode);
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;
    var status: uefi.Status = undefined;
    const GraphicsOutput = uefi.protocol.GraphicsOutput;

    var gop: *GraphicsOutput = undefined;
    if (video_info.device_handle) |handle| {
        status = boot_services.handleProtocol(handle, &GraphicsOutput.guid, @as(*?*anyopaque, @ptrCast(&gop)));
    } else {
        status = boot_services.locateProtocol(&GraphicsOutput.guid, null, @as(*?*anyopaque, @ptrCast(&gop)));
    }
    switch (status) {
        .Success => log.debug("Located graphics output protocol", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.LocateGraphicOutputError;
        },
    }

    var mode_id: u32 = 0;
    while (mode_id < gop.mode.max_mode) : (mode_id += 1) {
        var info_size: usize = 0;
        var info: *GraphicsOutput.Mode.Info = undefined;
        status = gop.queryMode(mode_id, &info_size, &info);
        switch (status) {
            .Success => log.debug("Successfully queried mode {d}", .{mode_id}),
            else => {
                log.err("Expected Success but got {s} instead", .{@tagName(status)});
                continue;
            },
        }

        if (info.vertical_resolution < video_info.resolution.height or info.horizontal_resolution < video_info.resolution.width) continue;
        switch (info.pixel_format) {
            GraphicsOutput.PixelFormat.RedGreenBlueReserved8BitPerColor, GraphicsOutput.PixelFormat.BlueGreenRedReserved8BitPerColor => {},
            else => continue,
        }

        log.debug(
            \\GOP Mode info:
            \\  Framebuffer: 0x{X}
            \\  Resolution: {d}x{d}
            \\  scan line: {d}
            \\  pixel format: {s}
        , .{
            gop.mode.frame_buffer_base,
            info.horizontal_resolution,
            info.vertical_resolution,
            info.pixels_per_scan_line,
            @tagName(info.pixel_format),
        });

        status = gop.setMode(mode_id);
        switch (status) {
            .Success => log.debug("Successfully set mode to {d}", .{mode_id}),
            else => {
                log.err("Expected Success but got {s} instead", .{@tagName(status)});
                continue;
            },
        }
        break;
    }

    var fillBuffer = [_]GraphicsOutput.BltPixel{.{ .red = 255, .green = 0, .blue = 0 }};
    status = gop.blt(&fillBuffer, GraphicsOutput.BltOperation.BltVideoFill, 0, 0, 0, 0, 250, 250, 0);
}

fn getPreferredResolution() BootloaderError!VideoInfo {
    const log = std.log.scoped(.edid);
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;
    var status: uefi.Status = undefined;
    var handles_count: usize = 0;
    var handles: [*]uefi.Handle = undefined;
    status = boot_services.locateHandleBuffer(.ByProtocol, &uefi.protocol.GraphicsOutput.guid, null, &handles_count, &handles);
    switch (status) {
        .Success => log.debug("Found {d} video device handles", .{handles_count}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.GraphicOutputDeviceError;
        },
    }

    var i: usize = 0;
    while (i < handles_count) : (i += 1) {
        const device_handle: uefi.Handle = handles[i];
        var edid_protocol: *uefi.protocol.edid.Discovered = undefined;
        status = boot_services.handleProtocol(device_handle, &uefi.protocol.edid.Discovered.guid, @as(*?*anyopaque, @ptrCast(&edid_protocol)));
        switch (status) {
            .Success => log.debug("Found edid of size {d}", .{edid_protocol.size_of_edid}),
            .Unsupported => {
                log.warn("Handle {d} does not support EDID", .{i});
                continue;
            },
            else => {
                log.err("Expected Success but got {s} instead", .{@tagName(status)});
                return BootloaderError.GraphicOutputDeviceError;
            },
        }

        log.info("Found EDID on handle {d}", .{i});

        if (edid_protocol.edid) |edid| {
            // TODO: do actual edid block validation
            const x_res = @as(u16, edid[0x36 + 2]) | (@as(u16, (edid[0x36 + 4] & 0xF0)) << 4);
            const y_res = @as(u16, edid[0x36 + 5]) | (@as(u16, (edid[0x36 + 7] & 0xF0)) << 4);

            return .{ .device_handle = device_handle, .resolution = .{ .width = x_res, .height = y_res } };
        }
    }

    return BootloaderError.EdidNotFoundError;
}

fn readConfigFile() BootloaderError![]const u8 {
    const log = std.log.scoped(.config);
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;
    var status: uefi.Status = undefined;
    var file_system: *uefi.protocol.SimpleFileSystem = undefined;
    status = boot_services.locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @as(*?*anyopaque, @ptrCast(&file_system)));
    switch (status) {
        .Success => log.debug("Located the file system protocol", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.ConfigFileLoadError;
        },
    }

    var root: *uefi.protocol.File = undefined;
    status = file_system.openVolume(&root);
    switch (status) {
        .Success => log.debug("Successfully opened the root volume", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.ConfigFileLoadError;
        },
    }

    var config_file: *uefi.protocol.File = undefined;
    status = root.open(&config_file, utf16("\\SYS\\KERNEL.CON"), uefi.protocol.File.efi_file_mode_read, 0);
    switch (status) {
        .Success => log.debug("Opened config file", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.ConfigFileLoadError;
        },
    }

    var file_info_size: usize = 0;
    var file_info: *uefi.FileInfo = undefined;
    status = config_file.getInfo(&uefi.FileInfo.guid, &file_info_size, @as([*]u8, @ptrCast(file_info)));
    switch (status) {
        .BufferTooSmall => log.debug("Need to allocate {d} bytes for file info", .{file_info_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.ConfigFileLoadError;
        },
    }

    status = boot_services.allocatePool(.LoaderData, file_info_size, @as(*[*]align(8) u8, @ptrCast(@alignCast(&file_info))));
    defer _ = boot_services.freePool(@as([*]align(8) u8, @ptrCast(@alignCast(file_info))));
    switch (status) {
        .Success => log.debug("Allocated {d} bytes for file info", .{file_info_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.ConfigFileLoadError;
        },
    }

    status = config_file.getInfo(&uefi.FileInfo.guid, &file_info_size, @as([*]u8, @ptrCast(file_info)));
    switch (status) {
        .Success => log.debug("Got file info: file size is {d} bytes", .{file_info.file_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.ConfigFileLoadError;
        },
    }

    const page_count = 1;
    var contents: [*]align(4096) u8 = undefined;
    status = boot_services.allocatePages(.AllocateAnyPages, .LoaderData, page_count, &contents);
    switch (status) {
        .Success => log.debug("Allocated {d} pages for config file contents", .{page_count}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.ConfigFileLoadError;
        },
    }

    var file_buffer_size: usize = page_count * 4096;
    status = config_file.read(&file_buffer_size, contents);
    switch (status) {
        .Success => log.debug("Read file contents", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.ConfigFileLoadError;
        },
    }

    return contents[0..file_info.file_size];
}

fn parseConfig(config: []const u8) BootloaderError!BootloaderConfig {
    const log = std.log.scoped(.config_parser);
    var parsed: BootloaderConfig = .{};
    // NOTE: every config line is of format: "KEY=VALUE\n"
    var line_tokenizer = std.mem.tokenizeScalar(u8, config, '\n');
    while (line_tokenizer.next()) |line| {
        var kv_split_iterator = std.mem.splitScalar(u8, line, '=');
        if (kv_split_iterator.next()) |key| {
            const value = kv_split_iterator.rest();
            if (std.mem.eql(u8, key, "KERNEL")) {
                parsed.kernel = value;
            } else if (std.mem.eql(u8, key, "VIDEO")) {
                // NOTE: video resolution should be of format WxH (eg. 600x480)
                var vid_resolution_split_iterator = std.mem.splitScalar(u8, value, 'x');
                if (vid_resolution_split_iterator.next()) |w| {
                    const h = vid_resolution_split_iterator.rest();
                    const width = std.fmt.parseInt(u16, w, 10) catch {
                        log.err("Error while parsing width ({s}) (should be a valid u16)", .{w});
                        return BootloaderError.ConfigFileParseError;
                    };
                    const height = std.fmt.parseInt(u16, h, 10) catch {
                        log.err("Error while parsing height ({s}) (should be a valid u16)", .{h});
                        return BootloaderError.ConfigFileParseError;
                    };
                    parsed.video = .{ .width = width, .height = height };
                }
            }
        }
    }
    return parsed;
}

fn getMemMap() BootloaderError!void {
    const log = std.log.scoped(.memmap);
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;
    var status: uefi.Status = undefined;

    var mmap_size: usize = 0;
    var mmap: ?[*]uefi.tables.MemoryDescriptor = null;
    var mapKey: usize = undefined;
    var descriptor_size: usize = undefined;
    var desscriptor_version: u32 = undefined;
    status = boot_services.getMemoryMap(&mmap_size, mmap, &mapKey, &descriptor_size, &desscriptor_version);
    switch (status) {
        .BufferTooSmall => log.debug("Need {d} bytes for memory map buffer", .{mmap_size}),
        else => {
            log.err("Expected BufferTooSmall but got {s} instead", .{@tagName(status)});
            return BootloaderError.MemoryMapError;
        },
    }

    mmap_size += 2 * descriptor_size;
    status = boot_services.allocatePool(.LoaderData, mmap_size, @ptrCast(&mmap));
    switch (status) {
        .Success => log.debug("Allocated {d} bytes for memory map at {*}", .{ mmap_size, mmap }),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.MemoryMapError;
        },
    }

    status = boot_services.getMemoryMap(&mmap_size, mmap, &mapKey, &descriptor_size, &desscriptor_version);
    switch (status) {
        .Success => log.debug("Got memory map", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.MemoryMapError;
        },
    }

    log.info("descriptor size: expected={d}, actual={d}", .{ @sizeOf(uefi.tables.MemoryDescriptor), descriptor_size });

    var descriptor: *uefi.tables.MemoryDescriptor = undefined;
    var idx: usize = 0;
    const descriptors_count = mmap_size / descriptor_size;
    while (idx < descriptors_count) : (idx += 1) {
        descriptor = @ptrFromInt(idx * descriptor_size + @intFromPtr(mmap));
        log.info("- Type={s}; {X} -> {X} (size: {X} pages); attr={X}", .{ @tagName(descriptor.type), descriptor.physical_start, descriptor.physical_start + 4096 * descriptor.number_of_pages, descriptor.number_of_pages, @as(u64, @bitCast(descriptor.attribute)) });
    }
}
