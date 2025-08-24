const std = @import("std");
const constants = @import("constants");
const descriptors = @import("descriptors.zig");
const IDT = @import("descriptors/idt.zig");
const Context = @import("interrupt/types.zig").Context;
const ISR = @import("interrupt/types.zig").ISR;

const log = std.log.scoped(.interrupt);

fn genVectorISR(vector: comptime_int) ISR {
    log.info("Creating ISR for vector {d}", .{vector});
    return struct {
        pub fn handler() callconv(.naked) void {
            asm volatile ("cli");
            switch (vector) {
                8, 10...14, 17, 21 => {},
                else => {
                    asm volatile ("pushq $0");
                },
            }
            asm volatile ("pushq %[v]"
                :
                : [v] "n" (vector),
            );
            asm volatile ("jmp commonISR");
        }
    }.handler;
}

export fn commonISR() callconv(.naked) void {
    asm volatile (
        \\ pushq %%rax
        \\ pushq %%rbx
        \\ pushq %%rcx
        \\ pushq %%rdx
        \\ pushq %%rsi
        \\ pushq %%rdi
        \\ pushq %%rsp
        \\ pushq %%rbp
        \\ pushq %%r8
        \\ pushq %%r9
        \\ pushq %%r10
        \\ pushq %%r11
        \\ pushq %%r12
        \\ pushq %%r13
        \\ pushq %%r14
        \\ pushq %%r15

        // TODO: check for rsp alignment (8bytes maybe even 16)
        \\ pushq %%rsp
        \\ popq %%rdi
        \\ call dispatchInterrupt
        \\ popq %%r15
        \\ popq %%r14
        \\ popq %%r13
        \\ popq %%r12
        \\ popq %%r11
        \\ popq %%r10
        \\ popq %%r9
        \\ popq %%r8
        \\ popq %%rbp
        \\ popq %%rsp
        \\ popq %%rdi
        \\ popq %%rsi
        \\ popq %%rdx
        \\ popq %%rcx
        \\ popq %%rbx
        \\ popq %%rax
        \\ iretq
    );
}

export fn dispatchInterrupt(context: *Context) callconv(.c) void {
    _ = context;
    @panic("Dispatching interrupt");
}

pub fn init(idt: *IDT) void {
    log.info("Init interrupt", .{});
    inline for (0..constants.max_interrupt_vectors) |v| {
        idt.registerGate(v, .create(.{
            .typ = .interrupt_gate,
            .isr = genVectorISR(v),
        }));
    }

    idt.loadIDTR();
    asm volatile ("sti");
}
