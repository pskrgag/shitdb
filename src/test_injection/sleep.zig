const std = @import("std");
const Value = std.atomic.Value;
const Event = std.Io.Event;

const SleepPoint = struct {
    sleep: Event,
    went_to_sleep: Event,
    sleeping: Value(bool),
};

const SleepMap = std.StringHashMap(SleepPoint);

const io = std.testing.io;
var gpa = std.heap.DebugAllocator(.{}){};
var SleepPoints: SleepMap = undefined;
var initialized: bool = false;

// Assume single-threaded setup
fn init() void {
    if (initialized)
        return;

    SleepPoints = SleepMap.init(gpa.allocator());
    initialized = true;
}

// Suspends execution of current thread.
pub fn sleep(comptime name: []const u8) !void {
    init();

    const val = SleepPoints.getPtr(name);
    if (val) |v| {
        if (v.sleeping.cmpxchgStrong(false, true, .monotonic, .monotonic) == null) {
            v.went_to_sleep.set(io);
            try v.sleep.wait(io);
            v.sleep.reset();
        }
    }
}

pub fn wake(comptime name: []const u8) !void {
    std.debug.assert(initialized == true);

    const val = SleepPoints.getPtr(name);
    if (val) |v| {
        const old = v.sleeping.swap(false, .monotonic);

        std.debug.assert(old == true);
        v.sleep.set(io);
    }
}

pub fn wait_sleep(comptime name: []const u8) !void {
    init();

    const val = SleepPoints.getPtr(name);
    if (val) |v| {
        try v.went_to_sleep.wait(io);
    }
}

// Enable panic point
pub fn enable(comptime name: []const u8) !void {
    init();

    try SleepPoints.put(name, .{
        .sleep = .unset,
        .went_to_sleep = .unset,
        .sleeping = Value(bool).init(false),
    });
}

pub fn clear() void {
    SleepPoints.deinit();
    initialized = false;
}
