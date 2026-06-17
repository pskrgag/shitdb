const std = @import("std");
const ArchContext = @import("x86/context.zig").ArchContext;
const posix = std.posix;
const ListNode = std.DoublyLinkedList.Node;
const Allocator = std.mem.Allocator;

const StackSize = 5 << 20;

pub const SleepPoint = enum {
    LoadCurrentMemtable,
    WalWritten,
    WalSlotAllocated,

    Test,
    Test1,
};

pub const Fiber = struct {
    const EntryFn = *const fn (*anyopaque) void;
    const CleanupFn = *const fn (*anyopaque, Allocator) void;

    ctx: *ArchContext,
    stack: ?[]u8,
    arg: ?*anyopaque,
    cleanup: ?CleanupFn,
    node: ListNode,
    done: bool,
    sleep: ?SleepPoint,

    pub fn from_current(alloc: Allocator) !*Fiber {
        const self = try alloc.create(Fiber);

        self.* = .{
            .ctx = try alloc.create(ArchContext),
            .stack = null,
            .arg = null,
            .cleanup = null,
            .node = ListNode{},
            .done = false,
            .sleep = null,
        };
        return self;
    }

    pub fn new(f: EntryFn, arg: ?*anyopaque, cleanup: ?CleanupFn, parent: *Fiber, alloc: Allocator) !*Fiber {
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
                @intFromPtr(arg.?),
                @intFromPtr(stack.ptr + StackSize),
                &self.done,
                parent.ctx,
                alloc,
            ),
            .stack = stack,
            .arg = arg,
            .cleanup = cleanup,
            .done = false,
            .sleep = null,
        };
        return self;
    }

    pub fn deinit(self: *Fiber, alloc: Allocator) void {
        if (self.stack) |stack|
            posix.munmap(@alignCast(stack));

        if (self.arg) |arg| {
            if (self.cleanup) |cleanup|
                cleanup(arg, alloc);
        }

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
