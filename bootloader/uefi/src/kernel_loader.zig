const std = @import("std");
const uefi = std.os.uefi;
const elf = std.elf;
const Globals = @import("globals.zig");
const BootloaderError = @import("errors.zig").BootloaderError;
const Constants = @import("constants.zig");
const Address = @import("address_space.zig").Address;
const MemHelper = @import("mem_helper.zig");
const Dwarf = std.debug.Dwarf;

const log = std.log.scoped(.kernel_loader);

const debug_sections_count = std.enums.directEnumArrayLen(Dwarf.Section.Id, 0);
const null_debug_sections = .{null} ** debug_sections_count;
pub const MappingInfo = struct { paddr: Address = .{ .paddr = 0 }, vaddr: Address = .{ .vaddr = .{} }, len: u64 };
pub const KernelInfo = struct {
    entrypoint: u64,
    segment_mappings: [8]MappingInfo = undefined,
    segment_count: u8 = 0,
    debug_sections: [debug_sections_count]?Dwarf.Section = null_debug_sections,
    bootinfo_addr: ?u64 = null,
    fb_addr: ?u64 = null,
    env_addr: ?u64 = null,
};

pub fn loadExecutable(kernel_file: []const u8) BootloaderError!*KernelInfo {
    const kernel_signature = kernel_file[0..4];
    if (std.mem.eql(u8, kernel_signature, elf.MAGIC)) {
        log.info("Kernel matched ELF signature", .{});
        return loadElf(kernel_file);
    }

    return BootloaderError.InvalidKernelExecutable;
}

fn loadElf(kernel_file: []const u8) BootloaderError!*KernelInfo {
    var status: uefi.Status = undefined;
    const ehdr: *elf.Elf64_Ehdr = @as(*elf.Elf64_Ehdr, @ptrCast(@alignCast(@constCast(kernel_file.ptr))));
    if (ehdr.e_ident[elf.EI_CLASS] != elf.ELFCLASS64) {
        log.err("Unsupported class {d}", .{ehdr.e_ident[elf.EI_CLASS]});
        return BootloaderError.InvalidKernelExecutable;
    }

    if (ehdr.e_ident[elf.EI_DATA] != elf.ELFDATA2LSB) {
        log.err("Unsupported endianness {d}", .{ehdr.e_ident[elf.EI_DATA]});
        return BootloaderError.InvalidKernelExecutable;
    }

    if (ehdr.e_machine != .X86_64) {
        log.err("Unsupported machine {s}", .{@tagName(ehdr.e_machine)});
        return BootloaderError.InvalidKernelExecutable;
    }

    if (ehdr.e_type != .EXEC) {
        log.err("Unsupported type {s}", .{@tagName(ehdr.e_type)});
        return BootloaderError.InvalidKernelExecutable;
    }

    var kernel_info: *KernelInfo = undefined;
    status = Globals.boot_services._allocatePool(.loader_data, @sizeOf(KernelInfo), @ptrCast(&kernel_info));
    switch (status) {
        .success => log.debug("Allocated kernel info struct at {*}", .{kernel_info}),
        else => return BootloaderError.AllocateKernelInfo,
    }
    kernel_info.* = .{ .entrypoint = ehdr.e_entry };

    const pheaders = std.mem.bytesAsSlice(elf.Elf64_Phdr, kernel_file[ehdr.e_phoff .. ehdr.e_phoff + ehdr.e_phnum * ehdr.e_phentsize]);
    var mapping_idx: usize = 0;
    var ph_idx: usize = 0;
    while (ph_idx < ehdr.e_phnum) : ({
        ph_idx += 1;
    }) {
        const phdr = pheaders[ph_idx];

        if (phdr.p_type != elf.PT_LOAD) {
            continue;
        }

        const file_size = phdr.p_filesz;
        const mem_size = phdr.p_memsz;
        if (mem_size > MemHelper.mb(64)) {
            log.err("Kernel is too large ({d} bytes)", .{mem_size});
            return BootloaderError.KernelTooLargeError;
        }

        const pages_to_allocate = @divExact(std.mem.alignForward(u64, mem_size, Constants.arch_page_size), Constants.arch_page_size);
        const load_buffer = try MemHelper.allocatePages(pages_to_allocate, .KERNEL_MODULE);

        @memcpy(load_buffer[0..file_size], kernel_file[phdr.p_offset..][0..phdr.p_filesz]);

        const bss_size = mem_size - file_size;
        if (bss_size != 0) {
            @memset(load_buffer[file_size..mem_size], 0);
        }

        kernel_info.segment_mappings[mapping_idx].paddr = .{ .paddr = @intFromPtr(load_buffer) };
        kernel_info.segment_mappings[mapping_idx].vaddr = .{ .vaddr = @bitCast(phdr.p_vaddr) };
        kernel_info.segment_mappings[mapping_idx].len = mem_size;

        mapping_idx += 1;
    }
    kernel_info.segment_count = @intCast(mapping_idx);
    log.debug("loaded all executable program headers", .{});

    if (ehdr.e_shstrndx < ehdr.e_shnum) {
        const sheaders = std.mem.bytesAsSlice(elf.Elf64_Shdr, kernel_file[ehdr.e_shoff .. ehdr.e_shoff + ehdr.e_shnum * ehdr.e_shentsize]);

        const shstrtab_shdr = sheaders[ehdr.e_shstrndx];
        log.debug("shstrtab_sh.offset {d}", .{shstrtab_shdr.sh_offset});
        var shstrtab: []const u8 = kernel_file[shstrtab_shdr.sh_offset..][0..shstrtab_shdr.sh_size];

        var strtabOpt: ?elf.Elf64_Shdr = null;
        var symtabOpt: ?elf.Elf64_Shdr = null;
        var debug_sections: [debug_sections_count]?elf.Elf64_Shdr = .{null} ** debug_sections_count;
        var debug_sections_byte_size: u64 = 0;

        var sh_idx: usize = 0;
        while (sh_idx < ehdr.e_shnum) : (sh_idx += 1) {
            const shdr = sheaders[sh_idx];
            const section_name: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(shstrtab[shdr.sh_name..].ptr)));
            log.info("Found section with type {d} and name {s}", .{ shdr.sh_type, section_name });
            if (std.mem.eql(u8, section_name, ".symtab")) symtabOpt = shdr;
            if (std.mem.eql(u8, section_name, ".strtab")) strtabOpt = shdr;
            inline for (@typeInfo(Dwarf.Section.Id).@"enum".fields, 0..) |section_id, idx| {
                if (std.mem.eql(u8, section_name, "." ++ section_id.name)) {
                    debug_sections[idx] = shdr;
                    debug_sections_byte_size += shdr.sh_size;
                }
            }
        }

        const missing_debug_info =
            debug_sections[@intFromEnum(Dwarf.Section.Id.debug_info)] == null or
            debug_sections[@intFromEnum(Dwarf.Section.Id.debug_abbrev)] == null or
            debug_sections[@intFromEnum(Dwarf.Section.Id.debug_str)] == null or
            debug_sections[@intFromEnum(Dwarf.Section.Id.debug_line)] == null;
        if (missing_debug_info) {
            log.info("No kernel debug symbols found, skipping", .{});
        } else {
            const debug_sections_num_pages = @divExact(std.mem.Alignment.fromByteUnits(Constants.arch_page_size).forward(debug_sections_byte_size), Constants.arch_page_size);
            var debug_section_bytes = try MemHelper.allocatePages(debug_sections_num_pages, .KERNEL_MODULE);
            var debug_section_slice = debug_section_bytes[0..debug_sections_byte_size];
            var debug_section_cursor: u64 = 0;
            for (debug_sections, 0..) |maybe_section, idx| {
                if (maybe_section) |section| {
                    const section_bytes: []const u8 = kernel_file[section.sh_offset..][0..section.sh_size];
                    @memcpy(debug_section_slice[debug_section_cursor..][0..section_bytes.len], section_bytes);
                    defer debug_section_cursor += section_bytes.len;
                    kernel_info.debug_sections[idx] = .{
                        .data = debug_section_slice[debug_section_cursor..][0..section_bytes.len],
                        .virtual_address = section.sh_addr,
                        .owned = true,
                    };
                    log.info("debug section: {*} 0x{x}", .{kernel_info.debug_sections[idx].?.data.ptr, kernel_info.debug_sections[idx].?.virtual_address.?});
                }
            }
        }

        if (symtabOpt) |symtab_shdr| {
            if (strtabOpt) |strtab_shdr| {
                log.debug("Found symtab and strtab", .{});
                const strtab: []const u8 = kernel_file[strtab_shdr.sh_offset..][0..strtab_shdr.sh_size];
                const symbols_count = symtab_shdr.sh_size / symtab_shdr.sh_entsize;
                const symtab = std.mem.bytesAsSlice(elf.Elf64_Sym, kernel_file[symtab_shdr.sh_offset .. symtab_shdr.sh_offset + symtab_shdr.sh_size]);
                var sym_idx: usize = 0;
                while (sym_idx < symbols_count) : (sym_idx += 1) {
                    const symbol = symtab[sym_idx];
                    const symbol_name: [:0]const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(strtab[symbol.st_name..].ptr)));
                    log.debug("Found symbol {s}", .{symbol_name});
                    if (std.mem.eql(u8, symbol_name, "bootinfo")) {
                        log.info("Found bootinfo symbol with value 0x{X}", .{symbol.st_value});
                        kernel_info.bootinfo_addr = symbol.st_value;
                        continue;
                    }
                    if (std.mem.eql(u8, symbol_name, "fb")) {
                        log.info("Found framebuffer symbol with value 0x{X}", .{symbol.st_value});
                        kernel_info.fb_addr = symbol.st_value;
                        continue;
                    }
                    if (std.mem.eql(u8, symbol_name, "env")) {
                        log.info("Found env config symbol with value 0x{X}", .{symbol.st_value});
                        kernel_info.env_addr = symbol.st_value;
                        continue;
                    }
                }
            }
        }
    }

    return kernel_info;
}
