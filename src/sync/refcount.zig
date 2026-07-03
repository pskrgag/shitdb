const std = @import("std");
const Value = std.atomic.Value;
const futex = std.os.linux.futex;
const Allocator = std.mem.Allocator;

pub fn Referenced(T: type) type {
    return struct {
        parent: *RefCounted(T),
        data: *T,

        const Self = @This();

        pub fn get(self: *Self) *T {
            return self.data;
        }

        pub fn deinit(self: *Self) void {
            self.parent.put();
        }
    };
}

pub fn RefCounted(T: type) type {
    return struct {
        const ControlBlock = struct {
            counter: Value(u32),
            value: T,
        };
        block: *ControlBlock,

        const Self = @This();

        pub fn init(val: T, alloc: Allocator) !Self {
            const block = try alloc.create(ControlBlock);

            block.* = .{
                .value = val,
                .counter = Value(u32).init(1),
            };

            return .{ .block = block };
        }

        pub fn ref(self: *Self) Referenced(T) {
            const res = self.block.counter.fetchAdd(1, .monotonic);
            std.debug.assert(res != std.math.maxInt(u32));

            return .{ .data = &self.block.value, .parent = self };
        }

        pub fn into_inner(self: *Self) *T {
            std.debug.assert(self.block.counter.load(.monotonic) == 1);
            return &self.block.value;
        }

        fn put(self: *Self) void {
            // Should be release, since caller of wait_zero should observe our changes.
            const old = self.block.counter.fetchSub(1, .release);

            if (old == 2) {
                _ = futex(
                    &self.block.counter,
                    .{ .private = true, .cmd = .WAKE },
                    1,
                    .{ .timeout = null },
                    null,
                    0,
                );
            }
        }

        // ASSUMPTION: no concurrent inc's should happen.
        pub fn wait_one(self: *Self) void {
            // Try spinning for a while to avoid heavyweight syscall.
            const spins: usize = 100;

            for (0..spins) |_| {
                if (self.block.counter.load(.acquire) == 1) {
                    return;
                }

                std.atomic.spinLoopHint();
            }

            while (true) {
                const val = self.block.counter.load(.acquire);

                if (val == 1)
                    break;

                _ = futex(
                    &self.block.counter,
                    .{ .private = true, .cmd = .WAIT },
                    val,
                    .{ .timeout = null },
                    null,
                    0,
                );
            }
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.destroy(self.block);
        }
    };
}
