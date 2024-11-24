const std = @import("std");
const uefi = std.os.uefi;
const Globals = @import("globals.zig");
const BootInfo = @import("bootinfo.zig").BootInfo;
const BootloaderError = @import("errors.zig").BootloaderError;
const GraphicsOutput = uefi.protocol.GraphicsOutput;

const log = std.log.scoped(.video);

var boot_services: *uefi.tables.BootServices = undefined;
var gop: ?*GraphicsOutput = null;

pub const VideoResolution = struct {
    width: u16,
    height: u16,
};
pub const VideoInfo = struct {
    device_handle: ?uefi.Handle,
    resolution: VideoResolution,
};

pub fn init() void {
    boot_services = Globals.boot_services;
}

pub fn getPreferredResolution() BootloaderError!VideoInfo {
    var status: uefi.Status = undefined;
    var handles_count: usize = 0;
    var handles: [*]uefi.Handle = undefined;
    status = boot_services.locateHandleBuffer(.ByProtocol, &GraphicsOutput.guid, null, &handles_count, &handles);
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

pub fn getFramebuffer(video_info: VideoInfo, bootinfo: *BootInfo) BootloaderError!void {
    var status: uefi.Status = undefined;

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

    var graphics_output = gop.?;
    var mode_id: u32 = 0;
    while (mode_id < graphics_output.mode.max_mode) : (mode_id += 1) {
        var info_size: usize = 0;
        var info: *GraphicsOutput.Mode.Info = undefined;
        status = graphics_output.queryMode(mode_id, &info_size, &info);
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
            graphics_output.mode.frame_buffer_base,
            info.horizontal_resolution,
            info.vertical_resolution,
            info.pixels_per_scan_line,
            @tagName(info.pixel_format),
        });

        status = graphics_output.setMode(mode_id);
        switch (status) {
            .Success => log.debug("Successfully set mode to {d}", .{mode_id}),
            else => {
                log.err("Expected Success but got {s} instead", .{@tagName(status)});
                continue;
            },
        }

        bootinfo.fb_ptr = graphics_output.mode.frame_buffer_base;
        bootinfo.fb_width = info.horizontal_resolution;
        bootinfo.fb_height = info.vertical_resolution;
        bootinfo.fb_scanline_bytes = info.pixels_per_scan_line * 4;
        bootinfo.fb_pixelformat = switch (info.pixel_format) {
            GraphicsOutput.PixelFormat.RedGreenBlueReserved8BitPerColor => BootInfo.PixelFormat.RGBA,
            GraphicsOutput.PixelFormat.BlueGreenRedReserved8BitPerColor => BootInfo.PixelFormat.BGRA,
            else => unreachable,
        };

        break;
    }
}
pub fn fillRect(red: u8, green: u8, blue: u8) BootloaderError!void {
    var fillBuffer = [_]GraphicsOutput.BltPixel{.{ .red = red, .green = green, .blue = blue }};
    if (gop) |graphics_output| {
        const status = graphics_output.blt(&fillBuffer, GraphicsOutput.BltOperation.BltVideoFill, 0, 0, 0, 0, 10, 10, 0);
        switch (status) {
            .Success => log.debug("Located graphics output protocol", .{}),
            else => {
                log.err("Expected Success but got {s} instead", .{@tagName(status)});
                return BootloaderError.LocateGraphicOutputError;
            },
        }
    }
}
