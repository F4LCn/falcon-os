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
        .sanitize_thread = false,
        .omit_frame_pointer = true,
        .pic = true,
        .code_model = .kernel,
    });

    // switch (optimize) {
    //     .Debug => kernel_exe.root_module.strip = false,
    //     else => kernel_exe.root_module.strip = true,
    // }

    kernel_exe.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel_exe);

    const test_step = b.step("test", "Run tests");

    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .name = "all_tests",
        .optimize = .Debug,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
