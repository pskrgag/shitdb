const std = @import("std");

pub const Error = error{
    ForkFailed,
    WaitPidFailed,
};

fn runChild(comptime func: anytype, args: anytype) noreturn {
    const func_info = @typeInfo(@TypeOf(func)).@"fn";
    const Return = func_info.return_type orelse @compileError("fork helper requires a function with known return type");

    switch (@typeInfo(Return)) {
        .error_union => {
            _ = @call(.auto, func, args) catch |err| {
                std.debug.print("Unexpected error returned by forked task: {}\n", .{err});
                std.process.exit(0);
            };
        },
        else => {
            _ = @call(.auto, func, args);
        },
    }

    std.process.exit(0);
}

pub fn expectCrash(comptime func: anytype, args: anytype) !void {
    const pid = std.posix.system.fork();

    if (pid == -1) {
        std.debug.print("Failed to fork\n", .{});
        return Error.ForkFailed;
    }

    if (pid == 0) {
        const res = std.os.linux.setrlimit(.CORE, &.{ .cur = 0, .max = 0 });

        if (res != 0)
            @panic("Failed to set rlimit");

        runChild(func, args);
    }

    var status: u32 = 0;
    const res = std.posix.system.waitpid(@intCast(pid), &status, 0);

    if (res == -1) {
        std.debug.print("Failed to wait\n", .{});
        return Error.WaitPidFailed;
    }

    try std.testing.expect(status != 0);
}
