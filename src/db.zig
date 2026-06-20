const std = @import("std");
const Allocator = std.mem.Allocator;
const MemTable = @import("storage").MemTable;
const MemTableOpts = @import("storage").MemTableOpts;
const Manager = @import("db/manager.zig").Manager;
const HashTableTest = @import("test_utils").HashTableTest;
const Dir = std.Io.Dir;
const test_utils = @import("test_utils");

fn openOrCreateDir(io: std.Io, path: []const u8) !Dir {
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
    pub fn new(path: []const u8, alloc: Allocator, io: std.Io, opts: ?KeyValueOptions) !Self {
        const dir = try openOrCreateDir(io, path);
        const mem_opts = if (opts) |o| o.memtable else null;

        return .{ .manager = try Manager.new(dir, alloc, io, mem_opts) };
    }

    /// De-initializes db session
    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.manager.deinit(alloc);
    }
};

test "Simple API Test" {
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();
    const io = std.testing.io;

    std.Io.Dir.cwd().deleteTree(io, "test_db2") catch {};
    var new = try KeyValue.new("test_db2", allocator, io, null);
    defer {
        new.deinit(allocator);
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
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.Io.Dir.cwd().deleteTree(io, "test_db1") catch {};
    const tb = try KeyValue.new(
        "test_db1",
        allocator,
        io,
        KeyValueOptions{ .memtable = .{ .memtable_size = 1000 } },
    );

    defer {
        std.Io.Dir.cwd().deleteTree(io, "test_db1") catch {
            @panic("gg");
        };
    }

    // deinit will be called inside test_hash_table_equavalance. I HATE ZIG, it's even worse than C.
    try HashTableTest.test_hash_table_equavalance(tb, false, 500);
}

test "Shutdown and then boot" {
    const io = std.testing.io;
    var arena = std.heap.DebugAllocator(.{}){};
    defer {
        _ = arena.deinit();
    }
    const allocator = arena.allocator();

    std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {};
    var old = try KeyValue.new("test_db3", allocator, io, null);
    defer {
        std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {
            @panic("gg");
        };
    }

    inline for (1..200) |i| {
        try old.put("a" ** i, "a" ** i, allocator);
    }

    old.deinit(allocator);

    var new = try KeyValue.new("test_db3", allocator, io, null);
    defer new.deinit(allocator);

    inline for (1..200) |i| {
        const val = (try new.get("a" ** i, allocator)).?;
        defer allocator.free(val);

        try std.testing.expectEqualSlices(u8, val, "a" ** i);
    }
}

// test "WAL startup recovery" {
//     const builtin = @import("builtin");
//
//     // Zig spawns threads, so fork in multi-threaded env is not really supported
//     // (tho whole test is unsafe)
//     if (builtin.sanitize_thread) {
//         return;
//     }
//
//     const fi = @import("test_utils").Injections;
//     const Repeats = 10;
//
//     // Should crash after 100 additions
//     try fi.fault_injection.enable(.after_wal, Repeats);
//     defer fi.fault_injection.clear();
//
//     const io = std.testing.io;
//     var arena = std.heap.DebugAllocator(.{}){};
//     defer {
//         _ = arena.deinit();
//     }
//     const allocator = arena.allocator();
//
//     std.Io.Dir.cwd().deleteTree(io, "test_db4") catch {};
//
//     defer {
//         std.Io.Dir.cwd().deleteTree(io, "test_db4") catch {
//             @panic("gg");
//         };
//     }
//
//     const Child = struct {
//         fn run(child_alloc: Allocator, child_io: std.Io) !void {
//             var new = try KeyValue.new("test_db4", child_alloc, child_io, null);
//
//             inline for (1..Repeats * 2) |i| {
//                 try new.put("a" ** i, "a" ** i, child_alloc);
//             }
//         }
//     };
//
//     try test_utils.fork.expectCrash(Child.run, .{ allocator, io });
//
//     // Now try to check WAL
//     var new = try KeyValue.new("test_db4", allocator, io, null);
//     defer new.deinit(allocator);
//
//     try std.testing.expectEqual(new.manager.version.current_seq().get(), Repeats);
//     try std.testing.expect(new.manager.version.current_file_seq().get() != 0);
//
//     inline for (1..Repeats) |i| {
//         const val = (try new.get("a" ** i, allocator)).?;
//         defer allocator.free(val);
//
//         try std.testing.expectEqualSlices(u8, "a" ** i, val);
//     }
// }
