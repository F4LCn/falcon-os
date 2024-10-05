const std = @import("std");
const uefi = std.os.uefi;
const Globals = @import("globals.zig");
const BootloaderError = @import("errors.zig").BootloaderError;
const Constants = @import("constants.zig");

const log = std.log.scoped(.file_system);

var boot_services: *uefi.tables.BootServices = undefined;
var _file_system: *uefi.protocol.SimpleFileSystem = undefined;
var _root: *uefi.protocol.File = undefined;

pub const FileBuffer = struct {
    buffer: []u8,
    size: usize,

    pub fn getContents(self: *const FileBuffer) []u8 {
        return self.buffer[0..self.size];
    }
};

pub fn init() BootloaderError!void {
    var status: uefi.Status = undefined;
    boot_services = Globals.boot_services;
    status = boot_services.locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @as(*?*anyopaque, @ptrCast(&_file_system)));
    switch (status) {
        .Success => log.debug("Located the file system protocol", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }
    status = _file_system.openVolume(&_root);
    switch (status) {
        .Success => log.debug("Successfully opened the root volume", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }
}

pub fn loadFile(path: []const u8) BootloaderError!FileBuffer {
    var status: uefi.Status = undefined;

    var file_handle: *uefi.protocol.File = undefined;
    var utf16_buffer = [_:0]u16{0} ** 265;
    const len = std.unicode.utf8ToUtf16Le(&utf16_buffer, path[0..]) catch {
        return BootloaderError.InvalidPathError;
    };
    std.mem.replaceScalar(u16, &utf16_buffer, '/', '\\');
    log.debug("Converted str: {s} -> {any} ({d})", .{ path, utf16_buffer, len });
    status = _root.open(&file_handle, &utf16_buffer, uefi.protocol.File.efi_file_mode_read, 0);
    switch (status) {
        .Success => log.debug("Opened file {s}", .{path}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }

    var file_info_size: usize = 0;
    var file_info: *uefi.FileInfo = undefined;
    status = file_handle.getInfo(&uefi.FileInfo.guid, &file_info_size, @as([*]u8, @ptrCast(file_info)));
    switch (status) {
        .BufferTooSmall => log.debug("Need to allocate {d} bytes for file info", .{file_info_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }

    status = boot_services.allocatePool(.LoaderData, file_info_size, @as(*[*]align(8) u8, @ptrCast(@alignCast(&file_info))));
    defer _ = boot_services.freePool(@as([*]align(8) u8, @ptrCast(@alignCast(file_info))));
    switch (status) {
        .Success => log.debug("Allocated {d} bytes for file info", .{file_info_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }

    status = file_handle.getInfo(&uefi.FileInfo.guid, &file_info_size, @as([*]u8, @ptrCast(file_info)));
    switch (status) {
        .Success => log.debug("Got file info: file size is {d} bytes", .{file_info.file_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }

    var file_buffer_size = std.mem.alignForward(usize, @intCast(file_info.file_size), Constants.ARCH_PAGE_SIZE);
    const pages_to_allocate = @divExact(file_buffer_size, Constants.ARCH_PAGE_SIZE);
    var contents: [*]align(Constants.ARCH_PAGE_SIZE) u8 = undefined;
    status = boot_services.allocatePages(.AllocateAnyPages, .LoaderData, pages_to_allocate, &contents);
    switch (status) {
        .Success => log.debug("Allocated {d} pages for file {s} contents", .{ pages_to_allocate, path }),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }

    status = file_handle.read(&file_buffer_size, contents);
    switch (status) {
        .Success => log.debug("Read file contents", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }

    return .{ .buffer = contents[0..file_buffer_size], .size = file_info.file_size };
}
