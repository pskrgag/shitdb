const std = @import("std");
const Value = std.atomic.Value;

const PanicPoint = struct {
    count: Value(usize),
};

const PanicMap = std.StringHashMap(PanicPoint);

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
pub fn crash(comptime name: []const u8) void {
    init();

    const val = PanicPoints.getPtr(name);
    if (val) |v| {
        if (v.count.fetchSub(1, .monotonic) == 1)
            std.process.abort();
    }
}

// Enable panic point
pub fn enable(comptime name: []const u8, count: usize) !void {
    init();

    try PanicPoints.put(name, .{ .count = Value(usize).init(count) });
}

pub fn clear() void {
    PanicPoints.deinit();
    initialized = false;
}
