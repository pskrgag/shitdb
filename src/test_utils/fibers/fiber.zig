const std = @import("std");
const ArchContext = @import("x86/context.zig").ArchContext;
const posix = std.posix;
const ListNode = std.DoublyLinkedList.Node;
const Allocator = std.mem.Allocator;

const StackSize = 5 << 20;

pub const SleepPoint = enum {
    Load,
    Insert,

    Test,
};

pub const Fiber = struct {
    ctx: *ArchContext,
    stack: ?[]u8,
    node: ListNode,
    done: bool,
    sleep: ?SleepPoint,

    pub fn from_current(alloc: Allocator) !*Fiber {
        const self = try alloc.create(Fiber);

        self.* = .{
            .ctx = try alloc.create(ArchContext),
            .stack = null,
            .node = ListNode{},
            .done = false,
            .sleep = null,
        };
        return self;
    }

    pub fn new(f: *const fn () void, parent: *Fiber, alloc: Allocator) !*Fiber {
        const self = try alloc.create(Fiber);
        const stack = try posix.mmap(
            null,
            StackSize,
            .{ .READ = true, .WRITE = true },
            .{ .GROWSDOWN = true, .ANONYMOUS = true, .TYPE = .PRIVATE },
            -1,
            0,
        );

        self.* = .{
            .node = ListNode{},
            .ctx = try ArchContext.new(
                @intFromPtr(f),
                @intFromPtr(stack.ptr + StackSize),
                &self.done,
                parent.ctx,
                alloc,
            ),
            .stack = stack,
            .done = false,
            .sleep = null,
        };
        return self;
    }

    pub fn deinit(self: *Fiber, alloc: Allocator) void {
        if (self.stack) |stack|
            posix.munmap(@alignCast(stack));

        alloc.destroy(self.ctx);
        alloc.destroy(self);
    }

    pub fn switch_from(self: *const Fiber, from: *Fiber) void {
        self.ctx.switch_from(from.ctx);
    }

    pub fn is_done(self: *const Fiber) bool {
        return self.done;
    }
};
