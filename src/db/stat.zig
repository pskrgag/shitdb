const std = @import("std");
const Value = std.atomic.Value;
const Allocator = std.mem.Allocator;

pub const StatKind = enum(usize) {
    memtable_flush,
    compaction,
};

// TODO: make it per-thread to reduce contention.
pub const Statistics = struct {
    counters: [@typeInfo(StatKind).@"enum".fields.len]u64 = .{0} ** @typeInfo(StatKind).@"enum".fields.len,

    const Self = @This();

    pub fn new(alloc: Allocator) !*Self {
        const self = try alloc.create(Self);

        self.* = std.mem.zeroes(Self);
        return self;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        alloc.destroy(self);
    }

    pub fn read(self: *const Self, comptime stat: StatKind) u64 {
        return @atomicLoad(u64, &self.counters[@intFromEnum(stat)], .monotonic);
    }

    pub fn inc(self: *Self, comptime stat: StatKind) void {
        _ = @atomicRmw(u64, &self.counters[@intFromEnum(stat)], .Add, 1, .monotonic);
    }

    pub fn dec(self: *Self, comptime stat: StatKind) void {
        _ = @atomicRmw(u64, &self.counters[@intFromEnum(stat)], .Sub, 1, .monotonic);
    }

    pub fn add(self: *Self, comptime stat: StatKind, n: u64) void {
        _ = @atomicRmw(u64, &self.counters[@intFromEnum(stat)], .Add, n, .monotonic);
    }
};
