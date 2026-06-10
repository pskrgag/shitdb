const std = @import("std");
const Value = std.atomic.Value;

pub const PanicKind = enum {
    after_wal,
    after_insert_oom,
};

const PanicPoint = struct {
    count: Value(usize),
};

const PanicMap = std.AutoHashMap(PanicKind, PanicPoint);

var gpa = std.heap.DebugAllocator(.{}){};
var PanicPoints: PanicMap = undefined;
var initialized: bool = false;

// Assume single-threaded setup
fn init() void {
    if (initialized)
        return;

    PanicPoints = PanicMap.init(gpa.allocator());
    initialized = true;
}

// Conditionally crashes the execution
pub fn crash(comptime kind: PanicKind) void {
    if (!initialized)
        return;

    init();

    const val = PanicPoints.getPtr(kind);
    if (val) |v| {
        if (v.count.fetchSub(1, .monotonic) == 1)
            std.process.abort();
    }
}

// Enable panic point
pub fn enable(comptime kind: PanicKind, count: usize) !void {
    init();

    try PanicPoints.put(kind, .{ .count = Value(usize).init(count) });
}

pub fn clear() void {
    PanicPoints.deinit();
    initialized = false;
}
