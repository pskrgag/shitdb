const std = @import("std");
const zbench = @import("zbench");
const skiplist = @import("skiplist.zig");
const db = @import("db.zig");

fn noop(allocator: std.mem.Allocator) void {
    _ = allocator;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout: std.Io.File = .stdout();

    var bench = zbench.Benchmark.init(allocator, .{
        .max_iterations = 1024,
        .time_budget_ns = 500_000_000,
    });
    defer bench.deinit();

    try skiplist.add_benches(&bench);
    try db.add_benches(&bench);
    try bench.run(io, stdout);
}
