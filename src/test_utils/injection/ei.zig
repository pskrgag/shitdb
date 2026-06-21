const std = @import("std");
const Value = std.atomic.Value;

pub const ErrorKind = enum { wal_sync };

const ErrorPoint = struct {
    count: Value(usize),
};

const ErrorMap = std.AutoHashMap(ErrorKind, ErrorPoint);

var gpa = std.heap.DebugAllocator(.{}){};
var ErrorPoints: ErrorMap = undefined;
var initialized: bool = false;

// Assume single-threaded setup
pub fn init() void {
    if (initialized)
        return;

    ErrorPoints = ErrorMap.init(gpa.allocator());
    initialized = true;
}

// Conditionally crashes the execution
pub fn maybe_error(comptime kind: ErrorKind) !void {
    if (!initialized)
        return;

    const val = ErrorPoints.getPtr(kind);
    if (val) |v| {
        if (v.count.fetchSub(1, .monotonic) == 1) {
            return error.InjectedError;
        }
    }
}

// Enable panic point
pub fn enable(kind: ErrorKind, count: usize) !void {
    init();

    try ErrorPoints.put(kind, .{ .count = Value(usize).init(count) });
}

pub fn clear() void {
    ErrorPoints.deinit();
    initialized = false;
}
