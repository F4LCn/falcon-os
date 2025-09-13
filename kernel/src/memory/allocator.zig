const std = @import("std");
const Alignment = std.mem.Alignment;
const math = std.math;
const mem = std.mem;

const Allocator = @This();
const Error = std.mem.Allocator.Error;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    can_alloc: *const fn (*anyopaque, len: usize, alignment: Alignment) bool,
    alloc: *const fn (*anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8,
    resize: *const fn (*anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool,
    remap: *const fn (*anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8,
    free: *const fn (*anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void,
};

pub fn allocator(self: *@This()) std.mem.Allocator {
    return .{
        .ptr = self.ptr,
        .vtable = &.{
            .alloc = self.vtable.alloc,
            .resize = self.vtable.resize,
            .remap = self.vtable.remap,
            .free = self.vtable.free,
        },
    };
}

pub fn noResize(
    self: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    _ = self;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return false;
}

pub fn noRemap(
    self: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    _ = self;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

pub fn noFree(
    self: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    ret_addr: usize,
) void {
    _ = self;
    _ = memory;
    _ = alignment;
    _ = ret_addr;
}

pub inline fn rawAlloc(a: Allocator, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    return a.vtable.alloc(a.ptr, len, alignment, ret_addr);
}

pub inline fn rawResize(a: Allocator, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    return a.vtable.resize(a.ptr, memory, alignment, new_len, ret_addr);
}

pub inline fn rawRemap(a: Allocator, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return a.vtable.remap(a.ptr, memory, alignment, new_len, ret_addr);
}

pub inline fn rawFree(a: Allocator, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    return a.vtable.free(a.ptr, memory, alignment, ret_addr);
}

pub fn canCreate(a: Allocator, comptime T: type) bool {
    if (@sizeOf(T) == 0) {
        return true;
    }
    return a.canAllocWithSizeAndAlignment(@sizeOf(T), .of(T), 1);
}

pub fn create(a: Allocator, comptime T: type) Error!*T {
    if (@sizeOf(T) == 0) {
        const ptr = comptime std.mem.alignBackward(usize, math.maxInt(usize), @alignOf(T));
        return @ptrFromInt(ptr);
    }
    const ptr: *T = @ptrCast(try a.allocBytesWithAlignment(.of(T), @sizeOf(T), @returnAddress()));
    return ptr;
}

pub fn destroy(self: Allocator, ptr: anytype) void {
    const info = @typeInfo(@TypeOf(ptr)).pointer;
    if (info.size != .one) @compileError("ptr must be a single item pointer");
    const T = info.child;
    if (@sizeOf(T) == 0) return;
    const non_const_ptr = @as([*]u8, @ptrCast(@constCast(ptr)));
    self.rawFree(non_const_ptr[0..@sizeOf(T)], .fromByteUnits(info.alignment), @returnAddress());
}

pub fn canAlloc(self: Allocator, comptime T: type, n: usize) bool {
    return self.canAllocAdvanced(T, null, n);
}

pub fn alloc(self: Allocator, comptime T: type, n: usize) Error![]T {
    return self.allocAdvancedWithRetAddr(T, null, n, @returnAddress());
}

pub fn allocWithOptions(
    self: Allocator,
    comptime Elem: type,
    n: usize,
    comptime optional_alignment: ?Alignment,
    comptime optional_sentinel: ?Elem,
) Error!AllocWithOptionsPayload(Elem, optional_alignment, optional_sentinel) {
    return self.allocWithOptionsRetAddr(Elem, n, optional_alignment, optional_sentinel, @returnAddress());
}

pub fn allocWithOptionsRetAddr(
    self: Allocator,
    comptime Elem: type,
    n: usize,
    comptime optional_alignment: ?Alignment,
    comptime optional_sentinel: ?Elem,
    return_address: usize,
) Error!AllocWithOptionsPayload(Elem, optional_alignment, optional_sentinel) {
    if (optional_sentinel) |sentinel| {
        const ptr = try self.allocAdvancedWithRetAddr(Elem, optional_alignment, n + 1, return_address);
        ptr[n] = sentinel;
        return ptr[0..n :sentinel];
    } else {
        return self.allocAdvancedWithRetAddr(Elem, optional_alignment, n, return_address);
    }
}

fn AllocWithOptionsPayload(comptime Elem: type, comptime alignment: ?Alignment, comptime sentinel: ?Elem) type {
    if (sentinel) |s| {
        return [:s]align(if (alignment) |a| a.toByteUnits() else @alignOf(Elem)) Elem;
    } else {
        return []align(if (alignment) |a| a.toByteUnits() else @alignOf(Elem)) Elem;
    }
}

pub fn allocSentinel(
    self: Allocator,
    comptime Elem: type,
    n: usize,
    comptime sentinel: Elem,
) Error![:sentinel]Elem {
    return self.allocWithOptionsRetAddr(Elem, n, null, sentinel, @returnAddress());
}

pub fn canAlignedAlloc(self: Allocator, comptime T: type, comptime alignment: ?Alignment, n: usize) bool {
    return self.canAllocAdvanced(T, alignment, n);
}

pub fn alignedAlloc(
    self: Allocator,
    comptime T: type,
    comptime alignment: ?Alignment,
    n: usize,
) Error![]align(if (alignment) |a| a.toByteUnits() else @alignOf(T)) T {
    return self.allocAdvancedWithRetAddr(T, alignment, n, @returnAddress());
}

pub inline fn allocAdvancedWithRetAddr(
    self: Allocator,
    comptime T: type,
    comptime alignment: ?Alignment,
    n: usize,
    return_address: usize,
) Error![]align(if (alignment) |a| a.toByteUnits() else @alignOf(T)) T {
    const a = comptime (alignment orelse Alignment.of(T));
    const ptr: [*]align(a.toByteUnits()) T = @ptrCast(try self.allocWithSizeAndAlignment(@sizeOf(T), a, n, return_address));
    return ptr[0..n];
}

fn canAllocAdvanced(self: Allocator, comptime T: type, comptime alignment: ?Alignment, n: usize) bool {
    const a = comptime (alignment orelse Alignment.of(T));
    return self.canAllocWithSizeAndAlignment(@sizeOf(T), a, n);
}

fn canAllocWithSizeAndAlignment(self: Allocator, comptime size: usize, comptime alignment: Alignment, n: usize) bool {
    const byte_count = math.mul(usize, size, n) catch return false;
    if (byte_count == 0) {
        return true;
    }
    return self.vtable.can_alloc(self.ptr, byte_count, alignment);
}

fn allocWithSizeAndAlignment(
    self: Allocator,
    comptime size: usize,
    comptime alignment: Alignment,
    n: usize,
    return_address: usize,
) Error![*]align(alignment.toByteUnits()) u8 {
    const byte_count = math.mul(usize, size, n) catch return Error.OutOfMemory;
    return self.allocBytesWithAlignment(alignment, byte_count, return_address);
}

fn allocBytesWithAlignment(
    self: Allocator,
    comptime alignment: Alignment,
    byte_count: usize,
    return_address: usize,
) Error![*]align(alignment.toByteUnits()) u8 {
    if (byte_count == 0) {
        const ptr = comptime alignment.backward(math.maxInt(usize));
        return @as([*]align(alignment.toByteUnits()) u8, @ptrFromInt(ptr));
    }

    const byte_ptr = self.rawAlloc(byte_count, alignment, return_address) orelse return Error.OutOfMemory;
    @memset(byte_ptr[0..byte_count], undefined);
    return @alignCast(byte_ptr);
}

pub fn resize(self: Allocator, allocation: anytype, new_len: usize) bool {
    const Slice = @typeInfo(@TypeOf(allocation)).pointer;
    const T = Slice.child;
    const alignment = Slice.alignment;
    if (new_len == 0) {
        self.free(allocation);
        return true;
    }
    if (allocation.len == 0) {
        return false;
    }
    const old_memory = mem.sliceAsBytes(allocation);
    // I would like to use saturating multiplication here, but LLVM cannot lower it
    // on WebAssembly: https://github.com/ziglang/zig/issues/9660
    //const new_len_bytes = new_len *| @sizeOf(T);
    const new_len_bytes = math.mul(usize, @sizeOf(T), new_len) catch return false;
    return self.rawResize(old_memory, .fromByteUnits(alignment), new_len_bytes, @returnAddress());
}

pub fn remap(self: Allocator, allocation: anytype, new_len: usize) t: {
    const Slice = @typeInfo(@TypeOf(allocation)).pointer;
    break :t ?[]align(Slice.alignment) Slice.child;
} {
    const Slice = @typeInfo(@TypeOf(allocation)).pointer;
    const T = Slice.child;

    const alignment = Slice.alignment;
    if (new_len == 0) {
        self.free(allocation);
        return allocation[0..0];
    }
    if (allocation.len == 0) {
        return null;
    }
    if (@sizeOf(T) == 0) {
        var new_memory = allocation;
        new_memory.len = new_len;
        return new_memory;
    }
    const old_memory = mem.sliceAsBytes(allocation);
    // I would like to use saturating multiplication here, but LLVM cannot lower it
    // on WebAssembly: https://github.com/ziglang/zig/issues/9660
    //const new_len_bytes = new_len *| @sizeOf(T);
    const new_len_bytes = math.mul(usize, @sizeOf(T), new_len) catch return null;
    const new_ptr = self.rawRemap(old_memory, .fromByteUnits(alignment), new_len_bytes, @returnAddress()) orelse return null;
    const new_memory: []align(alignment) u8 = @alignCast(new_ptr[0..new_len_bytes]);
    return mem.bytesAsSlice(T, new_memory);
}

pub fn realloc(self: Allocator, old_mem: anytype, new_n: usize) t: {
    const Slice = @typeInfo(@TypeOf(old_mem)).pointer;
    break :t Error![]align(Slice.alignment) Slice.child;
} {
    return self.reallocAdvanced(old_mem, new_n, @returnAddress());
}

pub fn reallocAdvanced(
    self: Allocator,
    old_mem: anytype,
    new_n: usize,
    return_address: usize,
) t: {
    const Slice = @typeInfo(@TypeOf(old_mem)).pointer;
    break :t Error![]align(Slice.alignment) Slice.child;
} {
    const Slice = @typeInfo(@TypeOf(old_mem)).pointer;
    const T = Slice.child;
    if (old_mem.len == 0) {
        return self.allocAdvancedWithRetAddr(T, .fromByteUnits(Slice.alignment), new_n, return_address);
    }
    if (new_n == 0) {
        self.free(old_mem);
        const ptr = comptime std.mem.alignBackward(usize, math.maxInt(usize), Slice.alignment);
        return @as([*]align(Slice.alignment) T, @ptrFromInt(ptr))[0..0];
    }

    const old_byte_slice = mem.sliceAsBytes(old_mem);
    const byte_count = math.mul(usize, @sizeOf(T), new_n) catch return Error.OutOfMemory;
    // Note: can't set shrunk memory to undefined as memory shouldn't be modified on realloc failure
    if (self.rawRemap(old_byte_slice, .fromByteUnits(Slice.alignment), byte_count, return_address)) |p| {
        const new_bytes: []align(Slice.alignment) u8 = @alignCast(p[0..byte_count]);
        return mem.bytesAsSlice(T, new_bytes);
    }

    const new_mem = self.rawAlloc(byte_count, .fromByteUnits(Slice.alignment), return_address) orelse
        return error.OutOfMemory;
    const copy_len = @min(byte_count, old_byte_slice.len);
    @memcpy(new_mem[0..copy_len], old_byte_slice[0..copy_len]);
    @memset(old_byte_slice, undefined);
    self.rawFree(old_byte_slice, .fromByteUnits(Slice.alignment), return_address);

    const new_bytes: []align(Slice.alignment) u8 = @alignCast(new_mem[0..byte_count]);
    return mem.bytesAsSlice(T, new_bytes);
}

pub fn free(self: Allocator, memory: anytype) void {
    const Slice = @typeInfo(@TypeOf(memory)).pointer;
    const bytes = mem.sliceAsBytes(memory);
    const bytes_len = bytes.len + if (Slice.sentinel() != null) @sizeOf(Slice.child) else 0;
    if (bytes_len == 0) return;
    const non_const_ptr = @constCast(bytes.ptr);
    @memset(non_const_ptr[0..bytes_len], undefined);
    self.rawFree(non_const_ptr[0..bytes_len], .fromByteUnits(Slice.alignment), @returnAddress());
}

pub fn dupe(self: Allocator, comptime T: type, m: []const T) Error![]T {
    const new_buf = try self.alloc(T, m.len);
    @memcpy(new_buf, m);
    return new_buf;
}

pub fn dupeZ(self: Allocator, comptime T: type, m: []const T) Error![:0]T {
    const new_buf = try self.alloc(T, m.len + 1);
    @memcpy(new_buf[0..m.len], m);
    new_buf[m.len] = 0;
    return new_buf[0..m.len :0];
}
