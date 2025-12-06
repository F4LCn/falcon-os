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
    .log_level = .info,
};

pub fn main() uefi.Status {
    logger.init(serial.Port.COM1);
    Globals.init();
    var trampoline_page: [*]u8 = @ptrFromInt(0x10000);
    var status = Globals.boot_services._allocatePages(.max_address, MemHelper.MemoryType.TRAMPOLINE.toUefi(), 1, @ptrCast(&trampoline_page));
    switch (status) {
        .success => {
            std.log.info("Reserved trampoline page {*}", .{trampoline_page});
        },
        else => {
            std.log.err("Failed to create trampoline page", .{});
            return uefi.Status.aborted;
        },
    }
    FileSystem.init() catch {
        std.log.err("Failed to initialize filesystem subsystem", .{});
        return uefi.Status.aborted;
    };
    Video.init();

    const bootinfo_page = MemHelper.allocatePages(1, .BOOTINFO) catch {
        std.log.err("Could not allocate a page for bootinfo struct", .{});
        return uefi.Status.aborted;
    };
    const bootinfo: *align(Constants.arch_page_size) BootInfo = @ptrCast(bootinfo_page);
    bootinfo.* = .{
        .bootloader_type = .UEFI,
        .mmap = .{
            .ptr = 0xABABABAB,
            .len = 12345,
        },
    };

    const config = FileSystem.loadFile(.{ .path = "/SYS/KERNEL.CON", .type = .BOOTINFO }) catch {
        std.log.err("Failed to load config file", .{});
        return uefi.Status.aborted;
    };
    std.log.debug(
        \\Got config:
        \\{s}"
    , .{config.getContents()});

    const bootloader_config = Config.parseConfig(config.getContents()) catch {
        std.log.err("Failed to parse config", .{});
        return uefi.Status.aborted;
    };
    std.log.info(
        \\Parsed config file
        \\Kernel file: {s}
        \\Video resolution: {d} x {d}
        \\Page offset: 0x{x}
    , .{
        bootloader_config.kernel,
        bootloader_config.video.width,
        bootloader_config.video.height,
        bootloader_config.page_offset,
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
        return uefi.Status.aborted;
    };
    Video.fillRect(255, 8, 4) catch {
        std.log.err("FillRect failed", .{});
        return uefi.Status.aborted;
    };

    var kernel = FileSystem.loadFile(.{ .path = bootloader_config.kernel }) catch {
        std.log.err("Could not load kernel file", .{});
        return uefi.Status.aborted;
    };

    const kernel_info = KernelLoader.loadExecutable(kernel.getContents(), bootloader_config.page_offset) catch {
        std.log.err("Could not load kernel executable", .{});
        return uefi.Status.aborted;
    };
    if (kernel_info.debug_info_ptr) |debug_info_ptr| bootinfo.debug_info_ptr = debug_info_ptr;

    std.log.debug("Bootinfo struct: {any}", .{bootinfo});

    std.log.debug("Kernel info: ", .{});
    std.log.debug("  entrypoint: 0x{x}", .{kernel_info.entrypoint});
    std.log.debug("  entry count: {d}", .{kernel_info.segment_count});
    if (kernel_info.debug_info_ptr) |_| {
        std.log.debug("  debug info loaded @ 0x{x}", .{kernel_info.debug_info_ptr});
    }
    for (0..kernel_info.segment_count) |idx| {
        const mapping = kernel_info.segment_mappings[idx];
        const mapping_vaddr = switch (mapping.vaddr) {
            .vaddr => |x| @as(u64, @bitCast(x)),
            else => unreachable,
        };
        const mapping_paddr = switch (mapping.paddr) {
            .paddr => |x| @as(u64, @bitCast(x)),
            else => unreachable,
        };
        std.log.info("  mapping[{d}]: p=0x{x} v=0x{x} l={d}", .{ idx, @as(u64, mapping_paddr), @as(u64, mapping_vaddr), mapping.len });
    }

    var addr_space = AddressSpace.create() catch {
        std.log.err("Could not create address space", .{});
        return uefi.Status.aborted;
    };

    mapStacks(&addr_space) catch {
        std.log.err("Could not map stacks", .{});
        return uefi.Status.aborted;
    };
    mapKernel(&addr_space, &kernel_info, @intFromPtr(bootinfo), @intFromPtr(config.buffer)) catch {
        std.log.err("Could not map kernel address space", .{});
        return uefi.Status.aborted;
    };
    mapLowMemory(&addr_space) catch {
        std.log.err("Could not map low memory", .{});
        return uefi.Status.aborted;
    };

    std.log.debug("bootinfo page: {x}", .{bootinfo_page[0..200]});
    kernel.deinit() catch {
        std.log.err("Could not free kernel buffer", .{});
        return uefi.Status.aborted;
    };
    const memory_limit = Mmap.buildMmap(bootinfo) catch |e| {
        std.log.err("Failed to get memory map. Error: {}", .{e});
        return uefi.Status.aborted;
    };
    mapMemory(&addr_space, bootloader_config.page_offset, memory_limit) catch {
        std.log.err("Could not map memory", .{});
        return uefi.Status.aborted;
    };
    const map_key = Mmap.getMmapKey() catch |e| {
        std.log.err("Failed to get memory map key. Error: {}", .{e});
        return uefi.Status.aborted;
    };

    std.log.info("Num table Entries: {d}", .{Globals.sys_table.number_of_table_entries});
    const rsdp_ptr = blk: {
        var table_ptr: *anyopaque = undefined;
        for (0..Globals.sys_table.number_of_table_entries) |i| {
            const config_table = Globals.sys_table.configuration_table[i];
            if (config_table.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
                std.log.debug("Found ACPI v2.0 table {*}", .{config_table.vendor_table});
                break :blk config_table.vendor_table;
            } else if (config_table.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_10_table_guid)) {
                std.log.debug("Found ACPI v1.0 table {*}", .{config_table.vendor_table});
                table_ptr = config_table.vendor_table;
            }
        }
        break :blk table_ptr;
    };
    std.log.info("Config table: {*}", .{rsdp_ptr});
    bootinfo.acpi_ptr = @intFromPtr(rsdp_ptr);

    const trampoline_addr = @intFromPtr(trampoline_page);
    std.log.info(
        \\ preparing to exit boot services
        \\ trampoline page -> 0x{x}
        \\ page map -> 0x{x}
        \\ kernel_entry -> 0x{x}
        \\ memory limit -> 0x{x}
    , .{ trampoline_addr, addr_space.root, kernel_info.entrypoint, memory_limit });

    // TODO: exit boot services
    status = Globals.boot_services._exitBootServices(uefi.handle, map_key);
    switch (status) {
        .success => {
            std.log.info("Exited boot services. Handlng execution to kernel ...", .{});
        },
        else => {
            std.log.err("Could not exit boot services, bad map key", .{});
            while (true) {}
        },
    }

    // WARN: Don't use boot_services after this line

    asm volatile (
        \\ leaq .trampoline(%%rip), %rsi
        \\ leaq .trampoline_end(%%rip), %rcx
        \\ subq %rsi, %rcx
        \\ movq %[trampoline_addr], %rdi
        \\ rep movsb
        \\ jmp *%[trampoline_addr]
        \\ 
        \\ .trampoline:
        \\ mov %cr4, %rax
        \\ or $0x620, %rax
        \\ mov %rax, %cr4
        \\ mov %[kernel_entry], %rax
        \\ mov %[page_map], %cr3
        \\ jmp *%rax
        \\ _catch:
        \\ jmp _catch
        \\ .trampoline_end:
        :
        : [trampoline_addr] "r" (trampoline_addr),
          [page_map] "r" (addr_space.root),
          [kernel_entry] "r" (kernel_info.entrypoint),
        : .{
          .rax = true,
          .rsi = true,
          .rcx = true,
          .rdi = true,
        });

    while (true) {}
    return uefi.Status.timeout;
}

fn mapLowMemory(addr_space: *AddressSpace) BootloaderError!void {
    const log = std.log.scoped(.KernelSpaceMapper);
    const low_memory_limit: u64 = 0x100000;
    log.debug("Mapping identity low memory 0 -> 0x{x}", .{low_memory_limit});
    var i: u64 = 0;
    while (i < low_memory_limit) : (i += Constants.arch_page_size) {
        log.debug("Mapping identity 0x{x}", .{i});
        try addr_space.mmap(
            .{ .vaddr = @bitCast(i) },
            .{ .paddr = @bitCast(i) },
            AddressSpace.DefaultMmapFlags,
        );
    }
}
fn mapStacks(addr_space: *AddressSpace) BootloaderError!void {
    const log = std.log.scoped(.KernelSpaceMapper);
    log.info("Mapping kernel space", .{});
    var core_stack_vaddr: u64 = -%@as(u64, Constants.arch_page_size);
    for (0..Constants.max_cpu) |i| {
        const core_stack_ptr = try MemHelper.allocatePages(1, .ReservedMemoryType);
        log.debug("Mapping core[{d}] stack: 0x{x} -> [0x{x} -> 0x{x}]", .{
            i,
            @intFromPtr(core_stack_ptr),
            core_stack_vaddr,
            core_stack_vaddr +% Constants.arch_page_size,
        });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(core_stack_vaddr) },
            .{ .paddr = @intFromPtr(core_stack_ptr) },
            AddressSpace.DefaultMmapFlags,
        );
        core_stack_vaddr -%= Constants.arch_page_size;
    }
}

fn mapFramebuffer(addr_space: *AddressSpace, fb_addr: u64, fb_ptr: u64, fb_size: u64) BootloaderError!void {
    const log = std.log.scoped(.KernelSpaceMapper);
    // TODO: make sure the size is page aligned
    log.info("Mapping framebuffer from 0x{x} -> 0x{x} (0x{x})", .{ fb_ptr, fb_addr, fb_size });
    var fb_vaddr = fb_addr;
    var fb_paddr = fb_ptr;
    while (fb_paddr < fb_ptr + fb_size) : ({
        fb_paddr += Constants.arch_page_size;
        fb_vaddr += Constants.arch_page_size;
    }) {
        try addr_space.mmap(
            .{ .vaddr = @bitCast(fb_vaddr) },
            .{ .paddr = fb_paddr },
            AddressSpace.DefaultMmapFlags,
        );
    }
}

fn mapMemory(addr_space: *AddressSpace, page_offset: u64, memory_limit: ?u64) BootloaderError!void {
    const log = std.log.scoped(.KernelSpaceMapper);
    const memory_size: u64 = memory_limit orelse MemHelper.tb(64);
    var i: u64 = 0;
    log.info("Mapping physical memory to 0x{x}", .{page_offset});
    while (i < memory_size) : (i += Constants.arch_page_size) {
        try addr_space.mmap(
            .{ .vaddr = @bitCast(i +% page_offset) },
            .{ .paddr = @bitCast(i) },
            AddressSpace.DefaultMmapFlags,
        );
    }
    // i = 0x400000;
    // log.info("Mapping physical memory to 0x{x}", .{page_offset});
    // while (i < memory_size) : (i += Constants.arch_page_size) {
    //     try addr_space.mmap(
    //         .{ .vaddr = @bitCast(i) },
    //         .{ .paddr = @bitCast(i) },
    //         AddressSpace.DefaultMmapFlags,
    //     );
    // }
}

fn mapKernel(
    addr_space: *AddressSpace,
    kernel_info: *const KernelLoader.KernelInfo,
    bootinfo_ptr: u64,
    env_ptr: u64,
) BootloaderError!void {
    const log = std.log.scoped(.KernelSpaceMapper);
    // env
    if (kernel_info.env_addr) |env_addr| {
        log.info("Mapping env map 0x{x} -> 0x{x}", .{ env_ptr, env_addr });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(env_addr) },
            .{ .paddr = env_ptr },
            AddressSpace.DefaultMmapFlags,
        );
    }
    // bootinfo
    if (kernel_info.bootinfo_addr) |bootinfo_addr| {
        log.info("Mapping bootinfo struct 0x{x} -> 0x{x}", .{ bootinfo_ptr, bootinfo_addr });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(bootinfo_addr) },
            .{ .paddr = bootinfo_ptr },
            AddressSpace.DefaultMmapFlags,
        );
    } else {
        @panic("No bootinfo found");
    }
    // kernel
    var kernel_end: u64 = 0;
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
        log.debug("Mapping kernel segment 0x{x} -> 0x{x} {x}", .{
            @as(u64, @bitCast(mapping_paddr)),
            @as(u64, @bitCast(mapping_vaddr)),
            mapping.len,
        });
        const num_pages = ((mapping.len + Constants.arch_page_size - 1) / Constants.arch_page_size);
        for (0..num_pages) |p| {
            defer mapping_paddr += Constants.arch_page_size;
            defer mapping_vaddr += Constants.arch_page_size;
            log.debug("\t kernel segment[{d}] 0x{x} -> 0x{x}", .{
                p,
                @as(u64, @bitCast(mapping_paddr)),
                @as(u64, @bitCast(mapping_vaddr)),
            });
            try addr_space.mmap(
                .{ .vaddr = @bitCast(mapping_vaddr) },
                .{ .paddr = mapping_paddr },
                AddressSpace.DefaultMmapFlags,
            );
            kernel_end = mapping_vaddr;
        }
    }
    kernel_end += Constants.arch_page_size;

    const quickmap_start = kernel_end + 2 * Constants.arch_page_size;
    log.info("Kernel end found @ 0x{x}", .{kernel_end});
    const quickmap_pages = Constants.max_cpu;
    var quickmap_page = quickmap_start;
    const placeholder_addr: u64 = 0xDEADBEEF;
    for (0..quickmap_pages) |p| {
        defer quickmap_page += Constants.arch_page_size;
        log.info("\t Quickmap page[{d}] 0x{x} -> 0x{x}", .{
            p,
            @as(u64, @bitCast(placeholder_addr)),
            @as(u64, @bitCast(quickmap_page)),
        });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(quickmap_page) },
            .{ .paddr = placeholder_addr },
            AddressSpace.DefaultMmapFlags,
        );
    }

    const quickmap_pt_entry_length = std.mem.alignForward(u64, Constants.max_cpu * @sizeOf(AddressSpace.PageMapping.Entry), Constants.arch_page_size);
    const quickmap_pt_entry_pages = @divFloor(quickmap_pt_entry_length + Constants.arch_page_size - 1, Constants.arch_page_size);
    const quickmap_pt_entry_start = -%(@as(u64, Constants.arch_page_size) * Constants.max_cpu) - quickmap_pt_entry_length - 2 * Constants.arch_page_size;
    var quickmap_pt_entry_page = quickmap_pt_entry_start;
    quickmap_page = quickmap_start;
    for (0..quickmap_pt_entry_pages) |p| {
        defer quickmap_pt_entry_page += Constants.arch_page_size;
        defer quickmap_page += Constants.arch_page_size;

        const quickmap_page_addr: AddressSpace.Pml4VirtualAddress = @bitCast(quickmap_page);
        const pte_addr = try addr_space.getPageTableEntry(quickmap_page_addr, AddressSpace.DefaultMmapFlags);
        log.info("Quickmap PTE 0x{x} paddr=0x{x}", .{ @intFromPtr(pte_addr), pte_addr.getAddr() });
        const pte_page_addr = std.mem.alignBackward(u64, @intFromPtr(pte_addr), Constants.arch_page_size);
        log.info("\t Quickmap pte page[{d}] 0x{x} -> 0x{x}", .{
            p,
            @as(u64, @bitCast(pte_page_addr)),
            @as(u64, @bitCast(quickmap_pt_entry_page)),
        });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(quickmap_pt_entry_page) },
            .{ .paddr = pte_page_addr },
            AddressSpace.DefaultMmapFlags,
        );
    }
}
