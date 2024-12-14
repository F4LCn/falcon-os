extern var bootinfo: [*]u64;

export fn _start() callconv(.C) noreturn {
    // asm volatile (
    //     \\ call kernelMain
    // );
    kernelMain(12, 13, 14, 15);
    while (true) {}
}

export fn kernelMain(a: u32, b: u32, c: u32, d: u32) callconv(.C) void {
    var idx: u64 = 0;
    while (true) : (idx += 1) {
        bootinfo[idx] += @intCast(a + b + c + d);
    }
}
