const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .abi = .none,
        .ofmt = .elf,
        .os_tag = .freestanding,
    });
    const optimize = b.standardOptimizeOption(.{});
    const kernel_exe = b.addExecutable(.{
        .name = "kernel64.elf",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .omit_frame_pointer = true,
        .sanitize_thread = false,
    });
    kernel_exe.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel_exe);
}
