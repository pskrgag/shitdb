const std = @import("std");
const Value = std.atomic.Value;
const futex = std.os.linux.futex;

pub const SleepingCounter = struct {
    counter: Value(u32),

    pub fn init() SleepingCounter {
        return .{
            .counter = Value(u32).init(0),
        };
    }

    pub fn inc(self: *SleepingCounter) void {
        _ = self.counter.fetchAdd(1, .monotonic);
    }

    pub fn dec(self: *SleepingCounter) void {
        // Should be release, since caller of wait_zero should observe our changes.
        const old = self.counter.fetchSub(1, .release);

        if (old == 1) {
            _ = futex(
                &self.counter,
                .{ .private = true, .cmd = .WAKE },
                1,
                .{ .timeout = null },
                null,
                0,
            );
        }
    }

    // ASSUMPTION: no concurrent inc's should happen.
    pub fn wait_zero(self: *SleepingCounter) void {
        // Try spinning for a while to avoid heavyweight syscall.
        const spins: usize = 100;

        for (0..spins) |_| {
            if (self.counter.load(.acquire) == 0) {
                return;
            }

            std.atomic.spinLoopHint();
        }

        while (true) {
            const val = self.counter.load(.acquire);

            if (val == 0)
                break;

            _ = futex(
                &self.counter,
                .{ .private = true, .cmd = .WAIT },
                val,
                .{ .timeout = null },
                null,
                0,
            );
        }
    }
};

test "Basic test" {
    var cnt = SleepingCounter.init();

    cnt.wait_zero();
    cnt.inc();
    cnt.dec();
    cnt.wait_zero();
}

test "Waiter returns after final decrement" {
    const Worker = struct {
        fn wait(cnt: *SleepingCounter, started: *Value(bool), finished: *Value(bool)) void {
            started.store(true, .release);
            cnt.wait_zero();
            finished.store(true, .release);
        }
    };

    var cnt = SleepingCounter.init();
    cnt.inc();

    var started = Value(bool).init(false);
    var finished = Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Worker.wait, .{ &cnt, &started, &finished });

    while (!started.load(.acquire)) {
        std.atomic.spinLoopHint();
    }

    for (0..100) |_| {
        std.Thread.yield() catch {};
    }

    try std.testing.expect(!finished.load(.acquire));
    cnt.dec();
    thread.join();
    try std.testing.expect(finished.load(.acquire));
}

test "Concurrent decrements release waiter" {
    const decrement_count: usize = 16;
    const Worker = struct {
        fn dec(cnt: *SleepingCounter) void {
            cnt.dec();
        }
    };

    var cnt = SleepingCounter.init();
    for (0..decrement_count) |_| {
        cnt.inc();
    }

    var threads: [decrement_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.dec, .{&cnt});
    }

    cnt.wait_zero();

    for (threads) |thread| {
        thread.join();
    }
}

test "Counter can be reused after waiting" {
    const iterations: usize = 100;
    const Worker = struct {
        fn dec(cnt: *SleepingCounter) void {
            cnt.dec();
        }
    };

    var cnt = SleepingCounter.init();

    for (0..iterations) |_| {
        cnt.inc();
        const thread = try std.Thread.spawn(.{}, Worker.dec, .{&cnt});
        cnt.wait_zero();
        thread.join();
    }
}
