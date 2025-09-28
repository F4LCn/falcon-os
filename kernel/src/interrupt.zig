const std = @import("std");
const constants = @import("constants");
const arch = @import("arch");
const descriptors = @import("descriptors.zig");
const IDT = @import("descriptors/idt.zig");
const Context = @import("interrupt/types.zig").Context;
const x64 = @import("interrupt/x64.zig");
const SinglyLinkedList = @import("list.zig").SinglyLinkedList;

const log = std.log.scoped(.interrupt);

pub const InterruptHandler = struct {
    const HandlerFn = *const fn (self: *anyopaque, context: *const Context) bool;
    ctx: *anyopaque,
    handler: HandlerFn,
    next: ?*@This() = null,

    pub fn handle(self: *@This(), context: *const Context) bool {
        return self.handler(self.ctx, context);
    }
};

const InterruptHandlerList = SinglyLinkedList(InterruptHandler, .next);

var handlers_list: [arch.constants.max_interrupt_vectors]InterruptHandlerList = [_]InterruptHandlerList{.{}} ** arch.constants.max_interrupt_vectors;

export fn dispatchInterrupt(context: *Context) callconv(.c) void {
    // Interface "InterruptHandler"
    // Register one or more interrupt handlers
    // ? Call the handlers one by one (prob have some sort of mechanism to stop the propagation)
    // have default handlers in place just in case
    const vector = context.vector;
    const handler_list = handlers_list[vector];
    var iter = handler_list.iter();
    while (iter.next()) |handler| {
        if (handler.handle(context)) {
            return;
        }
    }
    defaultHandler(context);
}

fn defaultHandler(context: *Context) void {
    log.err(
        \\
        \\ ---------- EXCEPTION ----------
        \\ An interrupt has not been handled
        \\ Exception 0x{X}: {s}
        \\
        \\ Error code: 0x{X}
        \\ FLAGS: 0x{X}
        \\ CR2: 0x{X:0>16}
        \\ RIP: 0x{X:0>16}
        \\ RAX: 0x{X:0>16}
        \\ RBX: 0x{X:0>16}
        \\ RCX: 0x{X:0>16}
        \\ RDX: 0x{X:0>16}
        \\ RSI: 0x{X:0>16}
        \\ RDI: 0x{X:0>16}
        \\ RSP: 0x{X:0>16}
        \\ RBP: 0x{X:0>16}
        \\ R8 : 0x{X:0>16}
        \\ R9 : 0x{X:0>16}
        \\ R10: 0x{X:0>16}
        \\ R11: 0x{X:0>16}
        \\ R12: 0x{X:0>16}
        \\ R13: 0x{X:0>16}
        \\ R14: 0x{X:0>16}
        \\ R15: 0x{X:0>16}
        \\ CS : 0x{X}
        \\ ---------- EXCEPTION ----------
        \\
    , .{
        context.vector,        vectorToName(context.vector),
        context.error_code,    context.flags,
        asm volatile ("mov %%CR2, %[ret]"
            : [ret] "=r" (-> u64),
        ),
        context.rip,           context.registers.rax,
        context.registers.rbx, context.registers.rcx,
        context.registers.rdx, context.registers.rsi,
        context.registers.rdi, context.registers.rsp,
        context.registers.rbp, context.registers.r8,
        context.registers.r9,  context.registers.r10,
        context.registers.r11, context.registers.r12,
        context.registers.r13, context.registers.r14,
        context.registers.r15,
        context.cs,
    });

    // arch.assembly.haltEternally();
    unreachable;
}

fn vectorToName(vector: u64) []const u8 {
    return switch (vector) {
        0 => "#DE: Divide error",
        1 => "#DB: Debug exception",
        2 => "NMI: Non-maskable interrupt",
        3 => "#BP: Breakpoint",
        4 => "#OF: Overflow",
        5 => "#BR: Bound range exceeded",
        6 => "#UD: Invalid opcode",
        7 => "#NM: Device not available",
        8 => "#DF: Double fault",
        9 => "Coprocessor segment overrun",
        10 => "#TS: Invalid TSS",
        11 => "#NP: Segment not present",
        12 => "#SS: Stack segment fault",
        13 => "#GP: General protection",
        14 => "#PF: Page fault",
        15 => "",
        16 => "#MF: Math fault",
        17 => "#AC: Alignment check",
        18 => "#MC: Machine check",
        19 => "#XM: SIMD floating-point exception",
        20 => "#VE: Virtualization exception",
        21 => "#CP: Control protection exception",
        else => unreachable,
    };
}

pub fn init(idt: *IDT) void {
    log.info("Init interrupt", .{});
    inline for (0..arch.constants.max_interrupt_vectors) |v| {
        idt.registerGate(v, .create(.{
            .typ = .interrupt_gate,
            .isr = x64.genVectorISR(v),
        }));
    }

    idt.loadIDTR();
    asm volatile ("sti");
}

pub fn registerHandler(vector: u64, interrupt_handler: *InterruptHandler) void {
    var handle_list = &handlers_list[vector];
    handle_list.prepend(interrupt_handler);
    log.info("registering demo handler {any}", .{handle_list});
}
