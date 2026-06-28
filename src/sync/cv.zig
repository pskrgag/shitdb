const std = @import("std");
const Mutex = @import("mutex.zig").Mutex;
const InvalidID = @import("mutex.zig").InvalidID;
const Scheduler = @import("test_utils").Scheduler;
const Thread = std.Thread;

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

    fn update_owner(self: *Condition, mutex: *Mutex) void {
        const tid = Thread.getCurrentId();
        const old_owner = mutex.owner.swap(InvalidID, .monotonic);

        std.debug.assert(old_owner == tid);
        _ = self;
    }

    fn restore_owner(self: *Condition, mutex: *Mutex) void {
        const tid = Thread.getCurrentId();
        const old_owner = mutex.owner.swap(tid, .monotonic);

        std.debug.assert(old_owner == InvalidID);
        _ = self;
    }

    pub fn waitUncancelable(self: *Condition, io: std.Io, mutex: *Mutex) void {
        if (Scheduler.is_running()) {
            self.fiber_wait(io, mutex);
        } else {
            self.update_owner(mutex);
            defer self.restore_owner(mutex);

            self.cond.waitUncancelable(io, &mutex.mtx);
        }
    }

    pub fn wait(self: *Condition, io: std.Io, mutex: *Mutex) !void {
        if (Scheduler.is_running()) {
            self.fiber_wait(io, mutex);
        } else {
            self.update_owner(mutex);
            defer self.restore_owner(mutex);

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
