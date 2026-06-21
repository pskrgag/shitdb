const std = @import("std");
const Mutex = @import("mutex.zig").Mutex;
const Scheduler = @import("test_utils").Scheduler;

pub const Condition = struct {
    cond: std.Io.Condition,

    pub const init: Condition = .{ .cond = std.Io.Condition.init };

    fn fiber_wait(self: *Condition, io: std.Io, mutex: *Mutex) void {
        const epoch = self.cond.epoch.load(.monotonic);

        mutex.unlock(io);
        Scheduler.yield(.ConditionWait);

        if (epoch != self.cond.epoch.load(.monotonic)) {
            @panic("Condition was not signaled. Scheduler deadlock");
        }

        mutex.lockUncancelable(io);
    }

    pub fn waitUncancelable(self: *Condition, io: std.Io, mutex: *Mutex) void {
        if (Scheduler.is_running()) {
            self.fiber_wait(io, mutex);
        } else {
            self.cond.waitUncancelable(io, &mutex.mtx);
        }
    }

    pub fn wait(self: *Condition, io: std.Io, mutex: *Mutex) !void {
        if (Scheduler.is_running()) {
            self.fiber_wait(io, mutex);
        } else {
            try self.cond.wait(io, &mutex.mtx);
        }
    }

    pub fn signal(self: *Condition, io: std.Io) void {
        self.cond.signal(io);
    }

    pub fn broadcast(self: *Condition, io: std.Io) void {
        self.cond.broadcast(io);
    }
};
