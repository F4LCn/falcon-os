pub inline fn outb(port: u16, value: u8) void {
    return asm volatile (
        \\ outb %[value], %[port]
        :
        : [port] "{dx}" (port),
          [value] "{al}" (value),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile (
        \\ inb %[port], %[value]
        : [value] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub inline fn outString(port: u16, bytes: []const u8) usize {
    const unwritten_bytes = asm volatile (
        \\ rep outsb
        : [ret] "={rcx}" (-> usize),
        : [port] "{dx}" (port),
          [src] "{rsi}" (bytes.ptr),
          [len] "{rcx}" (bytes.len),
        : .{ .rcx = true, .rsi = true }
    );
    return bytes.len - unwritten_bytes;
}
