const std = @import("std");
const Allocator = std.mem.Allocator;
const MemTable = @import("storage").MemTable;
const MemTableOpts = @import("storage").MemTableOpts;
const Manager = @import("db/manager.zig").Manager;
const test_utils = @import("test_utils");
const fs = std.fs;

fn openOrCreateDir(path: []const u8) !std.fs.Dir {
    const opts = fs.Dir.OpenOptions{ .iterate = true };

    return std.fs.cwd().openDir(path, opts) catch |err| switch (err) {
        error.FileNotFound => {
            try std.fs.cwd().makeDir(path);
            return try std.fs.cwd().openDir(path, opts);
        },
        else => return err,
    };
}

/// key value storage options
pub const KeyValueOptions = struct {
    memtable: MemTableOpts,
};

/// Frontend class that provides an API for the database
pub const KeyValue = struct {
    manager: Manager,

    const Self = @This();

    /// Creates new key value storage at specific directory.
    pub fn put(self: *Self, key: []const u8, value: []const u8, alloc: Allocator) !void {
        try self.manager.put(key, value, alloc);
    }

    /// Returns a key associated with value
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        return self.manager.get(key);
    }

    /// Returns a key associated with value
    pub fn remove(self: *Self, key: []const u8, alloc: Allocator) !void {
        return self.manager.remove(key, alloc);
    }

    /// Creates new key value storage at specific directory.
    pub fn new(path: []const u8, alloc: Allocator, opts: ?KeyValueOptions) !Self {
        const dir = try openOrCreateDir(path);
        const mem_opts = if (opts) |o| o.memtable else null;
        return .{ .manager = try Manager.new(dir, path, alloc, mem_opts) };
    }
};

test "Simple API Test" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var new = try KeyValue.new("test", allocator, null);
    try new.put("hello", "world", allocator);
    try std.testing.expectEqualSlices(u8, new.get("hello").?, "world");
    try std.testing.expectEqual(new.get("world"), null);
    try new.remove("hello", allocator);
    try std.testing.expectEqual(new.get("hello"), null);
}

test "Test more than one memtable" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tb = try KeyValue.new("test_db1", allocator, KeyValueOptions{ .memtable = .{ .memtable_size = 1000 } });
    try test_utils.test_hash_table_equavalance(tb, false, 1000);
}
