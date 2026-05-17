const std = @import("std");
const Allocator = std.mem.Allocator;
const MemTable = @import("storage").MemTable;
const MemTableOpts = @import("storage").MemTableOpts;
const Manager = @import("db/manager.zig").Manager;
const test_utils = @import("test_utils");
const Dir = std.Io.Dir;
const io = std.Options.debug_io;

fn openOrCreateDir(path: []const u8) !Dir {
    const cwd = Dir.cwd();
    const opts = Dir.OpenOptions{ .iterate = true };

    return cwd.openDir(io, path, opts) catch |err| switch (err) {
        error.FileNotFound => {
            try cwd.createDir(io, path, .default_dir);
            return try cwd.openDir(io, path, opts);
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
    pub fn get(self: *Self, key: []const u8, alloc: Allocator) !?[]u8 {
        return try self.manager.get(key, alloc);
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

    /// De-initializes db session
    pub fn deinit(self: *Self) void {
        self.manager.deinit();
    }
};

test "Simple API Test" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    var new = try KeyValue.new("test_db2", allocator, null);
    defer {
        new.deinit();
        std.Io.Dir.cwd().deleteTree(io, "test_db2") catch {
            @panic("gg");
        };
    }
    try new.put("hello", "world", allocator);

    {
        const val = (try new.get("hello", allocator)).?;
        defer allocator.free(val);
        try std.testing.expectEqualSlices(u8, val, "world");
    }

    try std.testing.expectEqual(new.get("world", allocator), null);
    try new.remove("hello", allocator);
    try std.testing.expectEqual(new.get("hello", allocator), null);
}

test "Test more than one memtable" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tb = try KeyValue.new(
        "test_db1",
        allocator,
        KeyValueOptions{ .memtable = .{ .memtable_size = 1000 } },
    );

    defer {
        tb.deinit();
        std.Io.Dir.cwd().deleteTree(io, "test_db1") catch {
            @panic("gg");
        };
    }
    try test_utils.test_hash_table_equavalance(tb, false, 500);
}

test "Shutdown and then boot" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {};
    var old = try KeyValue.new("test_db3", allocator, null);
    defer {
        std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {
            @panic("gg");
        };
    }

    inline for (1..200) |i| {
        try old.put("a" ** i, "a" ** i, allocator);
    }

    old.deinit();

    var new = try KeyValue.new("test_db3", allocator, null);
    defer new.deinit();

    inline for (1..200) |i| {
        const val = (try new.get("a" ** i, allocator)).?;
        defer allocator.free(val);

        try std.testing.expectEqualSlices(u8, val, "a" ** i);
    }
}
