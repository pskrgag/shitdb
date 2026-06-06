const std = @import("std");
const ArchContext = @import("x86/context.zig").ArchContext;
const posix = std.posix;

const StackSize = 5 << 20;

const Fiber = struct {
    ctx: ArchContext,
    stack: []u8,

    pub fn new(f: *const fn () void) !Fiber {
        const stack = try posix.mmap(
            null,
            StackSize,
            .{ .READ = true, .WRITE = true },
            .{ .GROWSDOWN = true, .ANONYMOUS = true, .TYPE = .PRIVATE },
            -1,
            0,
        );

        return .{ .ctx = ArchContext.new(@intFromPtr(f), @intFromPtr(stack.ptr + StackSize)), .stack = stack };
    }
};

fn noop() void {}

test "Basic fiber" {
    const f = try Fiber.new(noop);

    _ = f;
}
