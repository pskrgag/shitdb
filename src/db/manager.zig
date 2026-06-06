const std = @import("std");
const MemTable = @import("storage").MemTable;
const MemTableOpts = @import("storage").MemTableOpts;
const Flusher = @import("flusher.zig").Flusher;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const Mutex = std.Io.Mutex;
const Version = @import("version.zig").Version;
const WalTable = @import("wal_table.zig").WalTable;
const test_utils = @import("test_utils");
const fi = test_utils.Injections;
const Statistics = @import("stat.zig").Statistics;
const Slab = @import("slab").Slab;

pub const MemTableSlab = Slab(WalTable, 20);

pub const Manager = struct {
    // Active MemTable
    active: std.atomic.Value(*WalTable),
    // Root folder
    root: Dir,
    // Root path
    path: []const u8,
    // Mutex that protects new table creation
    new_table_lock: Mutex,
    // MemTable options
    opts: MemTableOpts,
    // Current version of db
    version: *Version,
    // IO instance,
    io: std.Io,
    // Statistics
    stat: *Statistics,
    // MemTable allocator
    slab: *MemTableSlab,

    const Self = @This();

    pub fn new(dir: Dir, path: []const u8, alloc: Allocator, io: std.Io, opts: ?MemTableOpts) !Self {
        const real_opts = opts orelse MemTableOpts.default();
        const stat = try Statistics.new(alloc);
        errdefer stat.deinit(alloc);

        const slab = try alloc.create(MemTableSlab);
        errdefer alloc.destroy(slab);
        slab.* = try MemTableSlab.init(alloc, io);
        errdefer slab.deinit(alloc);

        const version = try Version.from_file_with_slab(dir, "MANIFEST", real_opts, stat, slab, io, alloc);
        const new_file_seq = version.new_file_seq();
        const new_table = slab.alloc();

        new_table.* = try WalTable.new(dir, opts, new_file_seq, version, io, alloc);

        return .{
            .version = version,
            .active = std.atomic.Value(*WalTable).init(new_table),
            .path = path,
            .root = dir,
            .new_table_lock = Mutex.init,
            .opts = real_opts,
            .io = io,
            .stat = stat,
            .slab = slab,
        };
    }

    fn allocate_new_table(self: *Self, old: *WalTable, alloc: Allocator) !void {
        self.new_table_lock.lockUncancelable(self.io);
        defer self.new_table_lock.unlock(self.io);

        if (self.active.load(.unordered) == old) {
            old.make_immune();

            const new_file_seq = self.version.new_file_seq();
            const new_table = self.slab.alloc();
            new_table.* = try WalTable.new(
                self.root,
                self.opts,
                new_file_seq,
                self.version,
                self.io,
                alloc,
            );

            // NOTE: swap BEFORE publishing a new table.
            const old_table = self.active.swap(new_table, .monotonic);
            std.debug.assert(old_table == old);

            // Put current table into the flusher
            self.version.insert(old);
        }
    }

    pub fn put(self: *Self, key: []const u8, value: []const u8, alloc: Allocator) !void {
        // consume would suffice, but whatever
        const table = self.active.load(.acquire);

        test_utils.Scheduler.yield(.Load);

        // Current table is full. Allocate new one
        table.put(key, value, self.version.next_seq()) catch |e| {
            if (e == error.OutOfMemory or e == error.Immutable) {
                try self.allocate_new_table(table, alloc);
                // It was updated. Retry the operation
                return self.put(key, value, alloc);
            } else {
                return e;
            }
        };
    }

    /// Removes a value from database
    pub fn remove(self: *Self, key: []const u8, alloc: Allocator) !void {
        // consume would suffice, but whatever
        const table = self.active.load(.acquire);

        // Current table is full. Allocate new one
        table.remove(key, self.version.next_seq()) catch |e| {
            if (e == error.OutOfMemory or e == error.Immutable) {
                try self.allocate_new_table(table, alloc);
                // It was updated. Retry the operation
                return self.remove(key, alloc);
            } else {
                return e;
            }
        };
    }

    /// Retrieves a value from database
    pub fn get(self: *Self, key: []const u8, alloc: Allocator) !?[]u8 {
        const table = self.active.load(.acquire);
        const val = try table.get(key, self.version.current_seq(), alloc);

        switch (val) {
            .Found => |v| {
                return v;
            },
            .Removed => return null,
            .NotFound => {
                // Resolve from other memtables
                return try self.version.get(key, self.root, self.io, alloc);
            },
        }
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        // here we expect that no other user accesses data-base
        const active = self.active.load(.acquire);

        self.version.flush_memtable(active, self.io, self.root, alloc) catch {
            @panic("failed to flush active memtable");
        };

        active.deinit(alloc);
        self.version.deinit(self.io, alloc);
        self.slab.free(active);
        self.slab.deinit(alloc);
        alloc.destroy(self.slab);
        self.stat.deinit(alloc);
        self.root.close(self.io);
    }
};

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

fn uaf_thread(manager: *Manager, alloc: Allocator) !void {
    try manager.put("hey", "bro", alloc);
}

// test "UAF during flush" {
//     const io = std.testing.io;
//     var arena = std.heap.DebugAllocator(.{}){};
//     defer {
//         _ = arena.deinit();
//     }
//     const allocator = arena.allocator();
//
//     std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {};
//
//     const dir = try openOrCreateDir(io, "test_db3");
//     defer {
//         std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {
//             @panic("gg");
//         };
//     }
//
//     var manager = try Manager.new(dir, "test_db3", allocator, io, .{ .memtable_size = 5000 });
//     defer manager.deinit(allocator);
//
//     const thread = try std.Thread.spawn(.{}, uaf_thread, .{ &manager, allocator });
//     try fi.sleep_injection.wait_sleep(.Load);
//
//     // Now insert a lot of shit and wait while active memtable is flushed
//     while (manager.stat.read(.memtable_flush) == 0) {
//         try manager.put("hey" ** 10, "baby" ** 10, allocator);
//     }
//
//     try fi.sleep_injection.wake(.Load);
//     thread.join();
// }
//
// test "In progress insert" {
//     const KeyValue = @import("storage").KeyValue;
//
//     defer fi.sleep_injection.clear();
//     try fi.sleep_injection.enable(.Insert);
//
//     const io = std.testing.io;
//     var arena = std.heap.DebugAllocator(.{}){};
//     defer {
//         _ = arena.deinit();
//     }
//     const allocator = arena.allocator();
//
//     std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {};
//
//     const dir = try openOrCreateDir(io, "test_db3");
//     defer {
//         std.Io.Dir.cwd().deleteTree(io, "test_db3") catch {
//             @panic("gg");
//         };
//     }
//
//     var manager = try Manager.new(dir, "test_db3", allocator, io, .{ .memtable_size = 100 });
//     defer manager.deinit(allocator);
//
//     const thread = try std.Thread.spawn(.{}, uaf_thread, .{ &manager, allocator });
//     try fi.sleep_injection.wait_sleep(.Insert);
//
//     try std.testing.expect(KeyValue.calculate_size("a" ** 35, "a" ** 35) < 100);
//
//     try std.testing.expectEqual(manager.stat.read(.memtable_flush), 0);
//     try manager.put("a" ** 35, "a" ** 35, allocator);
//     try std.testing.expectEqual(manager.stat.read(.memtable_flush), 0);
//     // This should trigger flush
//     try manager.put("a" ** 35, "a" ** 35, allocator);
//
//     try fi.sleep_injection.wake(.Insert);
//     thread.join();
// }
