const std = @import("std");
const Allocator = std.mem.Allocator;

export fn switch_ctx() callconv(.naked) void {
    asm volatile (
        \\ movq %%rbx, 0(%%rsi)
        \\ movq %%rbp, 8(%%rsi)
        \\ movq %%rsp, 16(%%rsi)
        \\ movq %%r12, 24(%%rsi)
        \\ movq %%r13, 32(%%rsi)
        \\ movq %%r14, 40(%%rsi)
        \\ movq %%r15, 48(%%rsi)
        \\ pushfq
        \\ popq 56(%%rsi)
        \\ movq 0(%%rdi), %%rbx
        \\ movq 8(%%rdi), %%rbp
        \\ movq 16(%%rdi), %%rsp
        \\ movq 24(%%rdi), %%r12
        \\ movq 32(%%rdi), %%r13
        \\ movq 40(%%rdi), %%r14
        \\ movq 48(%%rdi), %%r15
        \\ pushq 56(%%rdi)
        \\ popfq
        \\ ret
        ::: .{ .memory = true });
}

fn zig_entry_point(f: usize, arg: *anyopaque, self: *ArchContext) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    const ff: *const fn (*anyopaque) void = @ptrFromInt(f);

    ff(arg);
    self.done.* = true;
    self.scheduler.switch_from(self);

    std.debug.assert(false);
    while (true) {}
}

export fn entry_point() callconv(.naked) void {
        asm volatile (
            \\ movq %%r12, %%rdi
            \\ movq %%r14, %%rsi
            \\ movq %%r13, %%rdx
            \\ callq *%[zig_entry_point]
        \\ halt:
        \\ jmp halt
        :
        : [zig_entry_point] "r" (&zig_entry_point),
        : .{ .memory = true });
}

pub const ArchContext = extern struct {
    rbx: usize,
    rbp: usize,
    rsp: usize,
    r12: usize,
    r13: usize,
    r14: usize,
    r15: usize,
    flags: usize,
    done: *bool,
    scheduler: *ArchContext,

    // rdi -- 1st
    // rsi -- 2nd
    pub fn switch_from(to: *const ArchContext, from: *ArchContext) void {
        asm volatile (
            \\ movq %[to], %%rdi
            \\ movq %[from], %%rsi
            \\ callq *%[switch_ctx]
            :
            : [from] "r" (from),
              [to] "r" (to),
              [switch_ctx] "r" (&switch_ctx),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rsi = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .memory = true,
            });
    }

    pub fn new(ep: usize, arg: usize, stack: usize, done: *bool, scheduler: *ArchContext, alloc: Allocator) !*ArchContext {
        const self = try alloc.create(ArchContext);
        const stack_slot: [*]usize = @ptrFromInt(stack - 8);

        stack_slot[0] = @intFromPtr(&entry_point);

        self.* = .{
            .done = done,
            .scheduler = scheduler,
            .rbx = 0,
            .rbp = 0,
            .rsp = @intFromPtr(stack_slot),
            .r12 = ep,
            .r13 = @intFromPtr(self),
            .r14 = arg,
            .r15 = 0,
            .flags = 0,
        };

        return self;
    }
};
