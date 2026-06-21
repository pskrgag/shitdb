const std = @import("std");
const Thread = std.Thread;
const Value = std.atomic.Value;
const Scheduler = @import("test_utils").Scheduler;

// FIXME: assume linux semantics where TID != 0.
const InvalidID: Thread.Id = 0;
const AtomicID = Value(Thread.Id);

// Mutex with perks
pub const Mutex = struct {
    mtx: std.Io.Mutex,
    owner: AtomicID,

    pub const init: Mutex = .{
        .mtx = std.Io.Mutex.init,
        .owner = AtomicID.init(InvalidID),
    };

    pub fn lockUncancelable(self: *Mutex, io: std.Io) void {
        const tid = Thread.getCurrentId();

        defer {
            const old_owner = self.owner.swap(Thread.getCurrentId(), .monotonic);
            std.debug.assert(old_owner == InvalidID);
        }

        if (Scheduler.is_running()) {
            while (!self.mtx.tryLock()) {
                Scheduler.yield(.MutexWait);
            }
        } else {
            if (self.owner.load(.monotonic) == tid) {
                @panic("Mutex deadlock");
            }

            self.mtx.lockUncancelable(io);
        }
    }

    pub fn assert_locked(self: *Mutex) void {
        std.debug.assert(self.owner.load(.monotonic) == Thread.getCurrentId());
    }

    pub fn assert_not_locked(self: *Mutex) void {
        std.debug.assert(self.owner.load(.monotonic) != Thread.getCurrentId());
    }

    pub fn unlock(self: *Mutex, io: std.Io) void {
        const tid = Thread.getCurrentId();
        const old_owner = self.owner.swap(InvalidID, .monotonic);

        std.debug.assert(tid == old_owner);

        self.mtx.unlock(io);
    }
};
